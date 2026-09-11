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

/// Local host fixtures only. Native code is validated and copied, never executed.
/// Bundle/DevEco success recordings require explicit real, signed host inputs.
final class BootstrapInspectionControlContractTests: XCTestCase {
  private var root: URL!
  private var retainedRegistryRoot: URL?
  private var registryRoot: URL { retainedRegistryRoot ?? root.appending(path: "bootstrap") }
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/bootstrap-rpc-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-11T00:00:00Z" })
  }

  override func tearDownWithError() throws {
    engine = nil; capabilities = nil; dispatcher = nil; retainedRegistryRoot = nil
    try? FileManager.default.removeItem(at: root)
  }

  private static func bundleRegistry(_ directory: URL) -> BootstrapBundleRegistry {
    BootstrapBundleRegistry(root: directory, validateBundle: { candidate in
      do {
        _ = try LaunchAgentService.validateProductionDaemonBundle(candidate, fileManager: .default)
      } catch {
        throw AgentExecutionControlFailure("admissionDenied", "registered bundle failed the production helper trust policy")
      }
    }, nowUTC: { "2026-09-11T00:00:00Z" })
  }

  private func handler(configured: Bool = true, record: Bool = true, existingUserRegistry: Bool = false, registrationFailure: String? = nil) -> RuntimeControlPlaneHandler {
    let directory = registryRoot
    let tool: (@Sendable (String) async throws -> JSONValue)? = configured ? { @Sendable reference in
      let owner = try existingUserRegistry ? BootstrapBundleRegistry() : BootstrapBundleRegistry(root: directory)
      if reference.hasPrefix("toolchain:sha256:") {
        return try BootstrapDevEcoToolchainRegistry(owner: owner).inspect(reference, existingStoreOnly: true)
      }
      return try BootstrapToolRegistry(owner: owner, knownIdentity: { sha256 in
        HeadlessHDCBootstrapIdentity.lookup(sha256: sha256).map {
          BootstrapToolRegistry.PublishedIdentity(version: $0.version, profileReferences: $0.profileReferences)
        }
      }).inspect(reference, existingStoreOnly: true)
    } : nil
    let bundle: (@Sendable (String) async throws -> JSONValue)? = configured ? { @Sendable reference in
      try Self.bundleRegistry(directory).inspect(reference, existingStoreOnly: true)
    } : nil
    return RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-09-11T00:00:00Z" }, targetStore: nil, bootstrap: nil,
      bootstrapDevEcoRegistrar: configured ? { @Sendable path in
        if let registrationFailure { throw AgentExecutionControlFailure(registrationFailure, "injected registration failure for error-mapping contract") }
        return try BootstrapDevEcoToolchainRegistry(owner: Self.bundleRegistry(directory)).register(
          root: URL(filePath: path, directoryHint: .isDirectory))
      } : nil,
      bootstrapToolInspector: tool, bootstrapBundleInspector: bundle,
      artifactStore: nil, flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil, frameObserver: record ? nil : { @Sendable _ in })
  }

  private func wire(_ method: String, _ params: [String: JSONValue],
    configured: Bool = true, record: Bool = true, existingUserRegistry: Bool = false, registrationFailure: String? = nil) async throws -> AgentWireProtocol.Response {
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("bootstrap-fixture"), "method": .string(method), "params": .object(params),
    ])
    let reply = await handler(configured: configured, record: record, existingUserRegistry: existingUserRegistry, registrationFailure: registrationFailure).handleLine(
      try CanonicalJSONEncoders.canonical().encode(request))
    return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: reply)
  }

  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw AgentExecutionControlFailure("fixture", "expected object") }
    return fields
  }
  private func reference(_ value: JSONValue, _ key: String) throws -> String {
    guard case .string(let result)? = try object(value)[key] else {
      throw AgentExecutionControlFailure("fixture", "expected reference")
    }
    return result
  }
  private func nativeTool() throws -> JSONValue {
    try BootstrapToolRegistry(owner: Self.bundleRegistry(registryRoot)).register(file: URL(filePath: "/usr/bin/true"))
  }
  private func snapshot() throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: registryRoot.path) else { return [:] }
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: registryRoot,
      includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: String] = [:]
    for case let file as URL in enumerator {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let relative = String(file.path.dropFirst(registryRoot.path.count))
      let type = attributes[.type] as? FileAttributeType
      let contents = type == .typeRegular ? try SHA256Hex.string(of: Data(contentsOf: file)) : "directory"
      result[relative] = "\(attributes[.posixPermissions] ?? 0):\(contents)"
    }
    return result
  }
  private func assertFailure(_ result: AgentWireProtocol.Response, _ code: String,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(result.ok, file: file, line: line)
    XCTAssertNil(result.result, file: file, line: line)
    XCTAssertEqual(result.error?.code, code, file: file, line: line)
    XCTAssertEqual(result.error?.details?["newDispatchCount"], .integer(0), file: file, line: line)
    XCTAssertEqual(dispatcher.dispatchCount, 0, file: file, line: line)
  }

  func testExplicitRustHDCRegistryMatchesNativeSwiftReadbackWithoutWrites() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["ARKDECK_HDC_RUST_REGISTRY_ROOT"],
      let expectedReference = environment["ARKDECK_HDC_RUST_TOOL_REFERENCE"],
      let receiptPath = environment["ARKDECK_HDC_RUST_RECEIPT_PATH"] else {
      throw XCTSkip("requires an existing isolated Rust HDC registry and its actual producer receipt")
    }
    func physicalSystemAlias(_ path: String) -> String {
      for prefix in ["/tmp", "/var", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
        return "/private" + path
      }
      return path
    }
    let temporary = physicalSystemAlias(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
    let directory = URL(filePath: path, directoryHint: .isDirectory)
    guard path.hasPrefix("/private/tmp/") || path.hasPrefix(temporary + "/"),
      !path.utf8.contains(0), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      physicalSystemAlias(directory.resolvingSymlinksInPath().path) == directory.path,
      expectedReference.hasPrefix("tool:sha256:"),
      expectedReference.dropFirst("tool:sha256:".count).count == 64,
      expectedReference.dropFirst("tool:sha256:".count).allSatisfy({ "0123456789abcdef".contains($0) }),
      receiptPath.hasPrefix("/private/tmp/"), !receiptPath.utf8.contains(0),
      !receiptPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw AgentExecutionControlFailure("fixture", "HDC readback requires exact temporary inputs")
    }
    for name in [".lock", "bundles.json", "tools.json"] {
      let entry = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
      guard entry[.type] as? FileAttributeType == .typeRegular else {
        throw AgentExecutionControlFailure("fixture", "Rust registry metadata must already exist as regular files")
      }
    }
    let receipt = try object(JSONDecoder().decode(JSONValue.self,
      from: Data(contentsOf: URL(filePath: receiptPath))))
    XCTAssertEqual(receipt["bootstrapRoot"], .string(directory.path))
    XCTAssertEqual(receipt["deviceAcceptance"], .bool(false))
    let expected = try XCTUnwrap(receipt["result"])
    XCTAssertEqual(try object(expected)["toolRef"], .string(expectedReference))
    func retainedMetadata() throws -> [String: String] {
      let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]))
      var members = [directory]
      for case let entry as URL in enumerator {
        guard members.count < 300 else { throw AgentExecutionControlFailure("fixture", "readback registry exceeds its entry bound") }
        members.append(entry)
      }
      var result: [String: String] = [:]
      for entry in members {
        var status = stat()
        guard lstat(entry.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG || status.st_mode & S_IFMT == S_IFDIR else {
          throw AgentExecutionControlFailure("fixture", "readback registry contains an unsafe entry")
        }
        let bytes = status.st_mode & S_IFMT == S_IFREG
          ? try SHA256Hex.string(of: Data(contentsOf: entry)) : "directory"
        let identity = "\(status.st_dev):\(status.st_ino):\(status.st_mode):\(status.st_uid):\(status.st_gid):\(status.st_nlink):\(status.st_size)"
        let times = "\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec)"
        result[String(entry.path.dropFirst(directory.path.count))] = identity + ":" + times + ":" + bytes
      }
      return result
    }
    let before = try retainedMetadata()
    let tools = BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: directory), knownIdentity: { sha256 in
      HeadlessHDCBootstrapIdentity.lookup(sha256: sha256).map {
        BootstrapToolRegistry.PublishedIdentity(version: $0.version, profileReferences: $0.profileReferences)
      }
    })
    let actual = try tools.inspect(expectedReference, existingStoreOnly: true)
    XCTAssertEqual(actual, expected)
    XCTAssertEqual(try retainedMetadata(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    print("Rust HDC registry native Swift readback: " + String(decoding:
      try CanonicalJSONEncoders.canonical().encode(actual), as: UTF8.self))
  }

  func testDevEcoRegistrationProducerUsesNativeRootAndCanonicalVariants() async throws {
    let source = "/Applications/DevEco-Studio.app/Contents"
    guard FileManager.default.fileExists(atPath: source) else { throw XCTSkip("real DevEco app required") }
    let sourceInfo = URL(filePath: source).appending(path: "Info.plist")
    let sourceBefore = try Data(contentsOf: sourceInfo)
    let params: [String: JSONValue] = ["kind": .string("deveco"), "root": .string(source)]
    let first = try await wire("runtime.tool.register", params)
    XCTAssertTrue(first.ok, "\(String(describing: first.error))")
    let receipt = try XCTUnwrap(first.result)
    let toolRef = try reference(receipt, "toolRef")
    XCTAssertEqual(try object(receipt)["generation"], .string("1"))
    let before = try snapshot()
    for spelling in [source, source + "/"] {
      let again = try await wire("runtime.tool.register", ["kind": .string("deveco"), "root": .string(spelling)])
      XCTAssertTrue(again.ok, "\(String(describing: again.error))")
      XCTAssertEqual(again.result, receipt)
      XCTAssertEqual(try snapshot(), before)
    }
    // Foundation preserves an interior empty component in the registered identity.
    assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"),
      "root": .string(source.replacingOccurrences(of: "/Contents", with: "//Contents"))]), "resourceConflict")
    XCTAssertEqual(try snapshot(), before)
    let inspected = try await wire("runtime.tool.inspect", ["tool": .string(toolRef)], record: false)
    XCTAssertEqual(inspected.result, receipt)
    let server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler(),
      nowUTC: { "2026-09-11T00:00:00Z" })
    _ = try server.start()
    defer { server.stop() }
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = ["runtime", "tool", "register", "--kind", "deveco", "--root", source,
      "--socket", server.socketURL.path, "--output", "json"]
    let stdout = root.appending(path: "cli-register.json")
    FileManager.default.createFile(atPath: stdout.path, contents: nil)
    let handle = try FileHandle(forWritingTo: stdout)
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    if process.isRunning { process.terminate(); XCTFail("CLI registration timed out") }
    process.waitUntilExit()
    try handle.close()
    XCTAssertEqual(process.terminationStatus, 0)
    let envelope = try object(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: stdout)))
    XCTAssertEqual(envelope["result"], receipt)
    XCTAssertEqual(try snapshot(), before)
    // A real local reference owner remains attached when registration repeats.
    let referenced = try BootstrapDevEcoToolchainRegistry(owner: Self.bundleRegistry(registryRoot)).acquire(
      toolRef, owner: BootstrapToolRegistry.ReferenceOwner(kind: .controlAction, id: "registration-contract-consumer"))
    let referencedBefore = try snapshot()
    let repeatWithOwner = try await wire("runtime.tool.register", params)
    XCTAssertEqual(repeatWithOwner.result, referenced)
    XCTAssertEqual(try snapshot(), referencedBefore)
    XCTAssertEqual(try Data(contentsOf: sourceInfo), sourceBefore)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testDevEcoRegistrationProducerBoundsInputsAndOwnerFailures() async throws {
    let source = "/Applications/DevEco-Studio.app/Contents"
    for bad in ["relative", "/a/../b", "/a/./b", "/a\0b"] {
      assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"), "root": .string(bad)]), "invalidParams")
    }
    for bad: [String: JSONValue] in [[:], ["kind": .string("hdc"), "root": .string(source)],
      ["kind": .string("deveco"), "root": .null],
      ["kind": .string("deveco"), "root": .string(source), "extra": .bool(true)]] {
      assertFailure(try await wire("runtime.tool.register", bad, record: false), "invalidParams")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
    assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"), "root": .string(source)], configured: false), "operationUnavailable")
    assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"), "root": .string("/private/tmp")]), "invalidInput")
    assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"),
      "root": .string(root.appending(path: "missing.app/Contents").path)]), "fileIdentityChanged")
    assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"),
      "root": .string(root.appending(path: "missing/Contents").path)]), "invalidInput")
    try Data("corrupt".utf8).write(to: registryRoot.appending(path: "deveco-toolchains.json"))
    assertFailure(try await wire("runtime.tool.register", ["kind": .string("deveco"), "root": .string(source)]), "recordUnreadable")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testDevEcoRegistrationProducerPreservesClassifiedFailuresAndUnknownOutcome() async throws {
    let fields: [String: JSONValue] = ["kind": .string("deveco"), "root": .string("/Applications/DevEco-Studio.app/Contents")]
    for code in ["invalidInput", "fileIdentityChanged", "resourceConflict", "admissionDenied", "recordUnreadable", "quotaExceeded", "ioFailure", "outcomeUnknown"] {
      assertFailure(try await wire("runtime.tool.register", fields, registrationFailure: code), code)
    }
    assertFailure(try await wire("runtime.tool.register", fields, registrationFailure: "unclassified"), "outcomeUnknown")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
  }

  func testClosedReferenceValidationPrecedesOwnerAccess() async throws {
    for (method, key, prefix) in [
      ("runtime.tool.inspect", "tool", "tool:sha256:"),
      ("runtime.bundle.inspect", "bundle", "bundle:sha256:"),
    ] {
      let good = prefix + String(repeating: "a", count: 64)
      // Malformed structural vectors stay out of the typed-request corpus;
      // a real malformed reference below records the invalidParams error shape.
      let invalid: [[String: JSONValue]] = [[:], [key: .null], [key: .integer(1)],
        [key: .string(good), "path": .string("/private/tmp/forbidden")], ["wrong": .string(good)]]
      for fields in invalid {
        assertFailure(try await wire(method, fields, configured: false, record: false), "invalidParams")
      }
      assertFailure(try await wire(method, [key: .string("invalid-reference")]), "invalidParams")
      assertFailure(try await wire(method, [key: .string(good)], configured: false), "operationUnavailable")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
  }

  func testMissingRootLockAndIndexesAreNeverInitializedByInspection() async throws {
    let requests = [
      ("runtime.tool.inspect", "tool", "tool:sha256:" + String(repeating: "a", count: 64)),
      ("runtime.tool.inspect", "tool", "toolchain:sha256:" + String(repeating: "b", count: 64)),
      ("runtime.bundle.inspect", "bundle", "bundle:sha256:" + String(repeating: "c", count: 64)),
    ]
    for (method, key, ref) in requests {
      assertFailure(try await wire(method, [key: .string(ref)]), "recordUnreadable")
      XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
    }
    _ = try nativeTool()
    let lock = registryRoot.appending(path: ".lock")
    try FileManager.default.removeItem(at: lock)
    var before = try snapshot()
    for (method, key, ref) in requests {
      assertFailure(try await wire(method, [key: .string(ref)]), "recordUnreadable")
      XCTAssertEqual(try snapshot(), before)
    }
    // Existing local bootstrap behavior may establish its lock; RPC reads may not.
    _ = try nativeTool()
    for name in ["tools.json", "bundles.json"] {
      try FileManager.default.removeItem(at: registryRoot.appending(path: name))
      before = try snapshot()
      for (method, key, ref) in requests where name == "bundles.json" || key == "tool" {
        assertFailure(try await wire(method, [key: .string(ref)]), "recordUnreadable")
        XCTAssertEqual(try snapshot(), before)
      }
    }
  }

  func testNativeHDCReadSurvivesHandlerRestartWithoutSelectingOrChangingBytes() async throws {
    let expected = try nativeTool()
    let ref = try reference(expected, "toolRef")
    let before = try snapshot()
    for _ in 0..<2 {
      let result = try await wire("runtime.tool.inspect", ["tool": .string(ref)])
      XCTAssertTrue(result.ok)
      XCTAssertEqual(result.result, expected)
      XCTAssertEqual(try object(XCTUnwrap(result.result))["selected"], .bool(false))
    }
    assertFailure(try await wire("runtime.tool.inspect",
      ["tool": .string("tool:sha256:" + String(repeating: "a", count: 64))]), "resourceNotFound")
    assertFailure(try await wire("runtime.bundle.inspect",
      ["bundle": .string("bundle:sha256:" + String(repeating: "b", count: 64))]), "resourceNotFound")
    let lock = open(registryRoot.appending(path: ".lock").path, O_RDWR | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(lock, 0)
    defer { close(lock) }
    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
    assertFailure(try await wire("runtime.tool.inspect", ["tool": .string(ref)]), "resourceConflict")
    assertFailure(try await wire("runtime.bundle.inspect",
      ["bundle": .string("bundle:sha256:" + String(repeating: "b", count: 64))]), "resourceConflict")
    XCTAssertEqual(flock(lock, LOCK_UN), 0)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCorruptNativeContentFailsWithoutRepair() async throws {
    let value = try nativeTool()
    let ref = try reference(value, "toolRef")
    let directory = registryRoot.appending(path: "tool-\(String(ref.dropFirst(12))).hdc")
    let executable = directory.appending(path: "hdc")
    XCTAssertEqual(chmod(executable.path, 0o700), 0)
    try Data("corrupt fixture".utf8).write(to: executable)
    let before = try snapshot()
    assertFailure(try await wire("runtime.tool.inspect", ["tool": .string(ref)]), "recordUnreadable")
    XCTAssertEqual(try snapshot(), before)
  }

  func testCorruptIndexesAreNotReplacedOrReinitialized() async throws {
    let ref = try reference(nativeTool(), "toolRef")
    try Data("{invalid fixture index".utf8).write(to: registryRoot.appending(path: "tools.json"))
    var before = try snapshot()
    assertFailure(try await wire("runtime.tool.inspect", ["tool": .string(ref)]), "recordUnreadable")
    XCTAssertEqual(try snapshot(), before)
    try Data("{invalid fixture index".utf8).write(to: registryRoot.appending(path: "bundles.json"))
    before = try snapshot()
    assertFailure(try await wire("runtime.bundle.inspect",
      ["bundle": .string("bundle:sha256:" + String(repeating: "a", count: 64))]), "recordUnreadable")
    XCTAssertEqual(try snapshot(), before)
  }

  func testAdversarialRegisteredFixturesRecordOnlyRealNativeTrustRefusals() async throws {
    // Registration injection constructs adversarial stored input only, matching
    // the existing Bootstrap registry fixtures. Its claimed trust is never sent
    // through the wire or used as a positive oracle. Inspection uses the real
    // production native verifier and must refuse these non-executable bytes.
    let badBundle = root.appending(path: "UnsignedFixture.app")
    try FileManager.default.createDirectory(at: badBundle.appending(path: "Contents"),
      withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "fixture-1"],
      format: .xml, options: 0).write(to: badBundle.appending(path: "Contents/Info.plist"))
    try Data("negative fixture".utf8).write(to: badBundle.appending(path: "Contents/payload"))
    let adversarialBundle = BootstrapBundleRegistry(root: registryRoot, validateBundle: { _ in })
    let bundleRef = try reference(adversarialBundle.register(file: badBundle), "bundleRef")
    var before = try snapshot()
    assertFailure(try await wire("runtime.bundle.inspect", ["bundle": .string(bundleRef)]), "admissionDenied")
    XCTAssertEqual(try snapshot(), before)

    let contents = root.appending(path: "UnsignedDevEco.app/Contents")
    for relative in ["Resources", "sdk/default/openharmony", "tools/node/bin", "tools/hvigor/bin", "_CodeSignature"] {
      try FileManager.default.createDirectory(at: contents.appending(path: relative), withIntermediateDirectories: true)
    }
    try Data("""
      {"name":"DevEco Studio","version":"26.0.0.2","buildNumber":"26002","productCode":"DS",
       "productVendor":"Huawei","launch":[{"os":"macOS","arch":"aarch64"}]}
      """.utf8).write(to: contents.appending(path: "Resources/product-info.json"))
    try Data("""
      {"data":{"apiVersion":"26","platformVersion":"26.0.0","version":"26.0.0.25"}}
      """.utf8).write(to: contents.appending(path: "sdk/default/sdk-pkg.json"))
    let node = contents.appending(path: "tools/node/bin/node")
    try Data("non-executable adversarial node bytes".utf8).write(to: node)
    XCTAssertEqual(chmod(node.path, 0o755), 0)
    try Data("fixture hvigor".utf8).write(to: contents.appending(path: "tools/hvigor/bin/hvigorw.js"))
    try Data("fixture resource envelope".utf8).write(to: contents.appending(path: "_CodeSignature/CodeResources"))
    let injectedTrust: (URL) throws -> BootstrapToolTrust = { url in
      BootstrapToolTrust(signature: "verified",
        identifier: url.pathExtension == "app" ? "com.huawei.devecostudio.ds" : "node",
        teamIdentifier: url.pathExtension == "app" ? "TZEA3TN37Q" : "HX7739G8FX",
        codeDirectorySHA256: String(repeating: "a", count: 64))
    }
    let adversarialDevEco = BootstrapDevEcoToolchainRegistry(owner: adversarialBundle,
      inspectTrust: injectedTrust, inspectPublisherTrust: injectedTrust,
      verifySignedResources: { _, _ in })
    let toolRef = try reference(adversarialDevEco.register(root: contents), "toolRef")
    before = try snapshot()
    assertFailure(try await wire("runtime.tool.inspect", ["tool": .string(toolRef)]), "admissionDenied")
    XCTAssertEqual(try snapshot(), before)
  }

  func testExplicitlyRetainedNativeOwnerForCrossProcessComparison() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["ARKDECK_BOOTSTRAP_RETAIN_FIXTURE_ROOT"],
      let bundlePath = environment["ARKDECK_BOOTSTRAP_BUNDLE_FIXTURE"],
      let devecoPath = environment["ARKDECK_BOOTSTRAP_DEVECO_FIXTURE"] else {
      throw XCTSkip("requires an explicit fresh temporary output root and real signed native inputs")
    }
    guard path.hasPrefix("/private/tmp/"),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      !FileManager.default.fileExists(atPath: path) else {
      throw AgentExecutionControlFailure("fixture", "retained fixture output must be a fresh absolute /private/tmp path")
    }
    retainedRegistryRoot = URL(filePath: path)
    let bundles = Self.bundleRegistry(registryRoot)
    let bundle = try bundles.register(file: URL(filePath: bundlePath))
    let tool = try nativeTool()
    let deveco = try BootstrapDevEcoToolchainRegistry(owner: bundles).register(root: URL(filePath: devecoPath))
    let before = try snapshot()
    for (method, key, value) in [("runtime.bundle.inspect", "bundle", bundle),
      ("runtime.tool.inspect", "tool", tool), ("runtime.tool.inspect", "tool", deveco)] {
      let ref = try reference(value, key == "bundle" ? "bundleRef" : "toolRef")
      let response = try await wire(method, [key: .string(ref)])
      XCTAssertTrue(response.ok)
      XCTAssertEqual(response.result, value)
    }
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    // Only this opt-in fresh fixture survives teardown; no installed registry is used.
    print("Retained native bootstrap fixture: \(registryRoot.path)")
  }

  func testExplicitRustDevEcoRegistryIsReadBackWithoutWrites() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["ARKDECK_DEVECO_RUST_REGISTRY_ROOT"],
      let expected = environment["ARKDECK_DEVECO_RUST_TOOL_REFERENCE"] else {
      throw XCTSkip("requires an explicit existing Rust-written temporary registry and tool reference")
    }
    guard path.hasPrefix("/private/tmp/"), !path.utf8.contains(0),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      expected.hasPrefix("toolchain:sha256:"),
      expected.dropFirst("toolchain:sha256:".count).count == 64,
      expected.dropFirst("toolchain:sha256:".count).allSatisfy({ "0123456789abcdef".contains($0) }) else {
      throw AgentExecutionControlFailure("fixture", "readback requires a bounded temporary registry and exact DevEco reference")
    }
    let directory = URL(filePath: path, directoryHint: .isDirectory)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw AgentExecutionControlFailure("fixture", "existing Rust registry root must be a directory")
    }
    for name in [".lock", "bundles.json", "deveco-toolchains.json"] {
      let entry = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
      guard entry[.type] as? FileAttributeType == .typeRegular else {
        throw AgentExecutionControlFailure("fixture", "existing Rust registry metadata must be regular files")
      }
    }
    retainedRegistryRoot = directory
    let before = try snapshot()
    let owner = BootstrapBundleRegistry(root: directory)
    let value = try BootstrapDevEcoToolchainRegistry(owner: owner).inspect(expected, existingStoreOnly: true)
    let fields = try object(value)
    XCTAssertEqual(fields["toolRef"], .string(expected))
    XCTAssertEqual(fields["contentDigest"], .string(String(expected.dropFirst("toolchain:sha256:".count))))
    XCTAssertEqual(fields["kind"], .string("deveco"))
    XCTAssertEqual(fields["state"], .string("available"))
    XCTAssertEqual(fields["generation"], .string("1"))
    XCTAssertEqual(fields["selected"], .bool(false))
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    // Emit only the actual native owner result, with no reconstructed projection.
    let bytes = try CanonicalJSONEncoders.canonical().encode(value)
    print("Rust DevEco registry native Swift readback: " + String(decoding: bytes, as: UTF8.self))
  }

  func testExistingSelectedHDCIsInspectedWithoutWritingItsRegistry() async throws {
    guard let ref = ProcessInfo.processInfo.environment["ARKDECK_BOOTSTRAP_EXISTING_TOOL_REFERENCE"] else {
      throw XCTSkip("requires an explicit existing selected HDC reference; never registers or selects")
    }
    // Match BootstrapBundleRegistry's real-user lookup, ignoring HOME and any
    // container-specific home. This path is used only to check read invariants.
    var account = passwd(), resolved: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    guard getpwuid_r(geteuid(), &account, &buffer, buffer.count, &resolved) == 0,
      resolved != nil, let home = account.pw_dir, let path = String(validatingCString: home) else {
      throw AgentExecutionControlFailure("fixture", "current-user Bootstrap root is unavailable")
    }
    let directory = URL(filePath: path).appending(path: "Library/Application Support/ArkDeck/Bootstrap/v1")
    func memberSet() throws -> Set<String> {
      let entries = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path))
      return Set(entries.allObjects.compactMap { $0 as? String })
    }
    func indexBytes() throws -> [String: Data] {
      try Dictionary(uniqueKeysWithValues: ["bundles.json", "tools.json", "deveco-toolchains.json"].map {
        ($0, try Data(contentsOf: directory.appending(path: $0)))
      })
    }
    let members = try memberSet(), indexes = try indexBytes()
    let response = try await wire("runtime.tool.inspect", ["tool": .string(ref)], existingUserRegistry: true)
    XCTAssertTrue(response.ok)
    let fields = try object(XCTUnwrap(response.result))
    XCTAssertEqual(fields["toolRef"], .string(ref))
    XCTAssertEqual(fields["selected"], .bool(true))
    guard case .string(let generation)? = fields["activeSelectionGeneration"] else {
      return XCTFail("the existing selected tool must retain its string generation")
    }
    XCTAssertFalse(generation.isEmpty)
    XCTAssertEqual(try indexBytes(), indexes)
    XCTAssertEqual(try memberSet(), members)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
  }

  func testRealUnsignedNativeToolPublishesNullSigningMetadata() async throws {
    let source = root.appending(path: "unsigned-harmless")
    try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: source)
    // Remove only the fresh copy's signature. The actual candidate is never run;
    // Security.framework, rather than an injected closure, measures unsignedness.
    let strip = Process()
    strip.executableURL = URL(filePath: "/usr/bin/codesign")
    strip.arguments = ["--remove-signature", source.path]
    strip.standardOutput = FileHandle.nullDevice; strip.standardError = FileHandle.nullDevice
    try strip.run(); strip.waitUntilExit()
    XCTAssertEqual(strip.terminationStatus, 0)
    let actualTrust = try BootstrapToolTrust.inspect(source)
    XCTAssertEqual(actualTrust.signature, "unsigned")
    XCTAssertNil(actualTrust.identifier); XCTAssertNil(actualTrust.teamIdentifier)
    XCTAssertNil(actualTrust.codeDirectorySHA256)
    let expected = try BootstrapToolRegistry(owner: Self.bundleRegistry(registryRoot)).register(file: source)
    let ref = try reference(expected, "toolRef")
    let before = try snapshot()
    let response = try await wire("runtime.tool.inspect", ["tool": .string(ref)])
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.result, expected)
    let trust = try object(XCTUnwrap(object(XCTUnwrap(response.result))["trust"]))
    for key in ["signingIdentifier", "teamIdentifier", "codeDirectoryIdentitySHA256"] {
      XCTAssertEqual(trust[key], .null)
    }
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testRealSignedBundleInspection() async throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_BOOTSTRAP_BUNDLE_FIXTURE"] else {
      throw XCTSkip("requires an explicit real signed ArkDeck helper; no injected trust acceptance")
    }
    let expected = try Self.bundleRegistry(registryRoot).register(file: URL(filePath: path))
    let ref = try reference(expected, "bundleRef")
    let before = try snapshot()
    let result = try await wire("runtime.bundle.inspect", ["bundle": .string(ref)])
    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.result, expected)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testRealPublisherBoundDevEcoInspection() async throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_BOOTSTRAP_DEVECO_FIXTURE"] else {
      throw XCTSkip("requires an explicit real publisher-bound DevEco installation; no injected trust acceptance")
    }
    let owner = BootstrapDevEcoToolchainRegistry(owner: Self.bundleRegistry(registryRoot))
    let expected = try owner.register(root: URL(filePath: path))
    let ref = try reference(expected, "toolRef")
    let before = try snapshot()
    let result = try await wire("runtime.tool.inspect", ["tool": .string(ref)])
    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.result, expected)
    assertFailure(try await wire("runtime.tool.inspect",
      ["tool": .string("toolchain:sha256:" + String(repeating: "a", count: 64))]), "resourceNotFound")
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
