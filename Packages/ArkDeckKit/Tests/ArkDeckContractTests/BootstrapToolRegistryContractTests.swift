import Darwin
import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent
@testable import ArkDeckOpenHarmony
@testable import ArkDeckProcess
@testable import ArkDeckWorkflows

/// Native fixture binaries are inspected, never executed by these tests.
final class BootstrapToolRegistryContractTests: XCTestCase {
  private var root: URL!
  private enum Failure: Error { case injected }
  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-registry-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  private func registry(fault: @escaping (String) throws -> Void = { _ in }) -> BootstrapToolRegistry {
    .init(owner: BootstrapBundleRegistry(root: root.appending(path: "registry")), knownIdentity: { sha256 in
      HeadlessHDCBootstrapIdentity.lookup(sha256: sha256).map {
        BootstrapToolRegistry.PublishedIdentity(version: $0.version, profileReferences: $0.profileReferences)
      }
    }, fault: fault, nowUTC: { "2026-09-01T00:00:00Z" })
  }
  private func fixture(_ name: String = "fixture-hdc") throws -> URL {
    let url = root.appending(path: name)
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckFakeHDCFixture")
    try FileManager.default.copyItem(at: executable, to: url)
    return url
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw Failure.injected }; return fields
  }
  private func string(_ value: JSONValue?) throws -> String {
    guard case .string(let text)? = value else { throw Failure.injected }; return text
  }
  private func assertFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual((error as? AgentExecutionControlFailure)?.code, code, "\(error)", file: file, line: line)
    }
  }

  func testNativeCandidatePersistsWithoutSourceAndDoesNotGainExecutionAuthority() throws {
    let source = try fixture(), owner = registry()
    let first = try owner.register(file: source), fields = try object(first)
    let reference = try string(fields["toolRef"])
    XCTAssertEqual(try registry().register(file: source), first)
    XCTAssertEqual(fields["selected"], .bool(false))
    let trust = try object(XCTUnwrap(fields["trust"]))
    XCTAssertEqual(trust["registeredIdentity"], .bool(false)); XCTAssertEqual(trust["platformTrust"], .string("unverified"))
    XCTAssertEqual(trust["toolVersion"], .null)
    XCTAssertTrue([JSONValue.string("adHoc"), .string("verified")].contains(try XCTUnwrap(trust["signature"])))
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try registry().inspect(reference), first)
    let dependency = try BootstrapToolRegistry.ReferenceOwner(kind: .controlAction, id: "control-fixture")
    assertFailure("resourceConflict") { _ = try owner.resolveHDC(reference, expectedGeneration: "1", owner: dependency) }
    _ = try owner.acquire(reference, expectedGeneration: "1", owner: dependency)
    assertFailure("operationUnavailable") { _ = try owner.resolveHDC(reference, expectedGeneration: "1", owner: dependency) }
    assertFailure("resourceConflict") { _ = try registry().remove(reference, expectedGeneration: "1") }
    try registry().release(reference, owner: dependency)
    let removed = try registry().remove(reference, expectedGeneration: "1")
    XCTAssertEqual(try object(removed)["generation"], .string("2"))
    XCTAssertEqual(try registry().remove(reference, expectedGeneration: "1"), removed)
    XCTAssertEqual(try registry().inspect(reference), removed)
    assertFailure("resourceConflict") { _ = try registry().acquire(reference, expectedGeneration: "1", owner: dependency) }
    let data = root.appending(path: "registry/tool-\(try string(fields["contentDigest"])).hdc/hdc")
    XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
  }

  func testEachDurableOwnerBlocksRemovalIncludingActiveSelectionAndLease() throws {
    let row = try object(registry().register(file: fixture())), reference = try string(row["toolRef"])
    let kinds: [BootstrapBundleRegistry.ReferenceKind] = [.installation, .rollback, .controlAction, .job, .recovery, .agentExecution, .activeLease, .activeSelection, .workspacePreset]
    for kind in kinds {
      let owner = try BootstrapToolRegistry.ReferenceOwner(kind: kind, id: "owner-" + kind.rawValue)
      let pinned = try object(registry().acquire(reference, expectedGeneration: "1", owner: owner))
      XCTAssertEqual(pinned["selected"], .bool(kind == .activeSelection))
      assertFailure("resourceConflict") { _ = try registry().remove(reference, expectedGeneration: "1") }
      try registry().release(reference, owner: owner)
    }
    _ = try registry().remove(reference, expectedGeneration: "1")
    assertFailure("resourceConflict") { _ = try registry().register(file: fixture("duplicate")) }
  }

  func testQuarantineIsPreservedAndChangesTheReferenceWithoutChangingExecutableHash() throws {
    let source = try fixture()
    let original = try object(registry().register(file: source))
    let quarantine = Data("0081;fixture;ArkDeckTests;tool-fixture".utf8)
    XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, 0)
    let quarantined = try object(registry().register(file: source))
    XCTAssertNotEqual(quarantined["toolRef"], original["toolRef"])
    XCTAssertEqual(quarantined["executableSHA256"], original["executableSHA256"])
    let copy = root.appending(path: "registry/tool-\(try string(quarantined["contentDigest"])).hdc/hdc")
    var bytes = Data(count: quarantine.count)
    XCTAssertEqual(bytes.withUnsafeMutableBytes { getxattr(copy.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, quarantine.count)
    XCTAssertEqual(bytes, quarantine)
    XCTAssertEqual(quarantined["quarantineSHA256"], .string(SHA256Hex.string(of: quarantine)))
  }

  func testScriptsLinksDirectoriesSparseOversizedAndMissingInputsAreRefused() throws {
    assertFailure("ioFailure") { _ = try registry().register(file: root.appending(path: "absent")) }
    let script = root.appending(path: "script")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script); XCTAssertEqual(chmod(script.path, 0o700), 0)
    assertFailure("invalidInput") { _ = try registry().register(file: script) }
    assertFailure("invalidInput") { _ = try registry().register(file: root) }
    let native = try fixture()
    let symbolic = root.appending(path: "symbolic")
    try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: native)
    assertFailure("fileIdentityChanged") { _ = try registry().register(file: symbolic) }
    let hard = root.appending(path: "hard")
    XCTAssertEqual(link(native.path, hard.path), 0)
    assertFailure("invalidInput") { _ = try registry().register(file: hard) }
    let sparse = root.appending(path: "large")
    let fd = open(sparse.path, O_RDWR | O_CREAT | O_EXCL, 0o700)
    defer { close(fd) }
    XCTAssertEqual(ftruncate(fd, 256 * 1024 * 1024 + 1), 0)
    assertFailure("inputTooLarge") { _ = try registry().register(file: sparse) }
    XCTAssertEqual(try registry().list { _, rows in rows.count }, 0)
  }

  func testSourceAndCopiedSignatureWindowIdentityChangesCannotPublish() throws {
    let source = try fixture()
    let race = registry { point in
      if point == "copied" { XCTAssertEqual(chmod(source.path, 0o600), 0) }
    }
    assertFailure("fileIdentityChanged") { _ = try race.register(file: source) }
    XCTAssertEqual(chmod(source.path, 0o700), 0)
    let trustRace = BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: root.appending(path: "trust-race")), inspectTrust: { copy in
      let trust = try BootstrapToolTrust.inspect(copy)
      XCTAssertEqual(chmod(copy.path, 0o600), 0); XCTAssertEqual(chmod(copy.path, 0o700), 0)
      return trust
    })
    assertFailure("fileIdentityChanged") { _ = try trustRace.register(file: source) }
    XCTAssertEqual(try registry().list { _, rows in rows.count }, 0)
  }

  func testPublishedContentAndLostOrCorruptIndexesFailClosed() throws {
    let fields = try object(registry().register(file: fixture())), reference = try string(fields["toolRef"])
    let content = root.appending(path: "registry/tool-\(try string(fields["contentDigest"])).hdc/hdc")
    let fd = open(content.path, O_WRONLY); defer { close(fd) }
    var byte: UInt8 = 1
    XCTAssertEqual(pwrite(fd, &byte, 1, 32), 1)
    assertFailure("recordUnreadable") { _ = try registry().inspect(reference) }
    assertFailure("recordUnreadable") { _ = try registry().remove(reference, expectedGeneration: "1") }
    let index = root.appending(path: "registry/tools.json")
    try Data("{\"schemaVersion\":\"arkdeck.bootstrap-tools/1\",\"records\":[],\"records\":[]}".utf8).write(to: index)
    assertFailure("recordUnreadable") { _ = try registry().list { _, rows in rows } }
    try FileManager.default.removeItem(at: index)
    assertFailure("recordUnreadable") { _ = try registry().register(file: fixture("after-loss")) }
  }

  func testPublishedIdentityLookupDoesNotInventVersionOrProviderSupport() {
    XCTAssertEqual(HDCRegisteredToolIdentity.match(sha256: HDCReadOnlyProbeRegistry.targetExecutableSHA256)?.version, "3.2.0d")
    XCTAssertEqual(HDCRegisteredToolIdentity.match(sha256: HDCSupervisorObservationProbeCatalog.targetExecutableSHA256)?.version, "3.2.0f")
    XCTAssertNil(HDCRegisteredToolIdentity.match(sha256: String(repeating: "a", count: 64)))
  }

  func testInstalledSDKStaticRegistrationRetainsLibUSBAndNeedsNoOriginalPath() throws {
    // Host-only integration: inspect installed SDK bytes, never launch HDC.
    // CI without DevEco records a skip rather than claiming hardware evidence.
    let sdk = URL(filePath: "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains")
    guard FileManager.default.fileExists(atPath: sdk.appending(path: "hdc").path) else {
      throw XCTSkip("DevEco SDK is not installed; static host integration was not run")
    }
    let source = root.appending(path: "sdk")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    for name in ["hdc", "libusb_shared.dylib"] {
      try FileManager.default.copyItem(at: sdk.appending(path: name), to: source.appending(path: name))
    }
    let first = try registry().register(file: source.appending(path: "hdc")), row = try object(first)
    let reference = try string(row["toolRef"])
    XCTAssertEqual(row["relocatable"], .bool(true))
    guard case .array(let dependencies)? = row["dependencies"], dependencies.count == 1 else { return XCTFail("required libusb was not captured") }
    let library = try object(dependencies[0])
    XCTAssertEqual(library["name"], .string("libusb_shared.dylib"))
    XCTAssertEqual(library["sha256"], .string(SHA256Hex.string(of: try Data(contentsOf: source.appending(path: "libusb_shared.dylib")))))
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try registry().inspect(reference), first)
    let owner = try BootstrapToolRegistry.ReferenceOwner(kind: .controlAction, id: "static-sdk-consumer")
    _ = try registry().acquire(reference, expectedGeneration: "1", owner: owner)
    if HDCRegisteredToolIdentity.match(sha256: try string(row["executableSHA256"])) != nil {
      let resolved = try registry().resolveHDC(reference, expectedGeneration: "1", owner: owner)
      XCTAssertEqual(resolved.dependencies.count, 1)
      XCTAssertEqual(resolved.executableURL.lastPathComponent, "hdc")
      // Consumer retains the existing Process identities, not a second
      // executor implemented by the pre-daemon registration layer.
      let directory = try VerifiedDirectoryDescriptor.openOwnerOnly(path: resolved.executableURL.deletingLastPathComponent())
      let executable = try VerifiedRegularFileDescriptor.open(path: resolved.executableURL, expectedSHA256: resolved.executableSHA256, requireExecutable: true)
      let capturedLibrary = resolved.executableURL.deletingLastPathComponent().appending(path: "libusb_shared.dylib")
      let libraryIdentity = try VerifiedRegularFileDescriptor.open(path: capturedLibrary, expectedSHA256: resolved.dependencies[0].sha256)
      try directory.revalidate(); try executable.revalidate(); try libraryIdentity.revalidate()
      XCTAssertEqual(chmod(capturedLibrary.path, 0o600), 0)
      assertFailure("recordUnreadable") { _ = try registry().inspect(reference) }
      XCTAssertThrowsError(try libraryIdentity.revalidate())
    } else {
      assertFailure("operationUnavailable") { _ = try registry().resolveHDC(reference, expectedGeneration: "1", owner: owner) }
    }
  }

  func testImmutableToolListAndCLIHandlerUseTheSameOwner() throws {
    let source = try fixture()
    var rows: [JSONValue] = []
    for i in 0..<3 {
      let quarantine = Data("0081;fixture;tool;\(i)".utf8)
      XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, 0)
      rows.append(try registry().register(file: source))
    }
    func page(_ cursor: String?) throws -> [String: JSONValue] {
      try object(registry().list { directory, items in
        try RuntimeSnapshotPager(directory: directory).page(method: "runtime.tool.list", filters: [:], order: "toolRef:asc",
          pageSize: 1, cursor: cursor, items: { items })
      })
    }
    let cursor = try string(page(nil)["nextCursor"]), continuation = try page(cursor)
    guard case .array(let items)? = continuation["items"] else { throw Failure.injected }
    let removed = try string(object(XCTUnwrap(items.first))["toolRef"])
    _ = try registry().remove(removed, expectedGeneration: "1")
    XCTAssertEqual(try page(cursor), continuation)
    assertFailure("invalidCursor") {
      _ = try registry().list { directory, items in
        try RuntimeSnapshotPager(directory: directory).page(method: "runtime.tool.list", filters: [:], order: "toolRef:asc",
          pageSize: 2, cursor: cursor, items: { items })
      }
    }
    func invoke(_ args: [String]) throws -> [String: JSONValue] {
      let output = root.appending(path: "stdout-\(UUID()).json")
      let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard fd >= 0 else { throw Failure.injected }; defer { close(fd) }
      fflush(stdout)
      let original = dup(STDOUT_FILENO)
      guard original >= 0, dup2(fd, STDOUT_FILENO) >= 0 else { throw Failure.injected }
      defer { fflush(stdout); _ = dup2(original, STDOUT_FILENO); close(original) }
      try RuntimeCLI.runBootstrapTool(args + ["--output", "json", "--control-request-id", "tool-test"], registry: registry())
      fflush(stdout)
      return try object(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: output)))
    }
    let freshQuarantine = Data("0081;fixture;tool;fourth".utf8)
    XCTAssertEqual(freshQuarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, 0)
    let registered = try invoke(["register", "--kind", "hdc", "--file", source.path])
    XCTAssertEqual(registered["schemaVersion"], .string("arkdeck.cli.result/1"))
    XCTAssertEqual(registered["command"], .string("runtime.tool.register"))
    let reference = try string(object(XCTUnwrap(registered["result"]))["toolRef"])
    XCTAssertEqual(try invoke(["inspect", "--tool", reference])["result"], registered["result"])
    let listed = try invoke(["list", "--page-size", "4"])
    guard case .array(let all)? = try object(XCTUnwrap(listed["result"]))["items"] else { throw Failure.injected }
    XCTAssertEqual(all.count, rows.count + 1)
    let removal = try invoke(["remove", "--tool", reference, "--expected-generation", "1"])
    XCTAssertEqual(try object(XCTUnwrap(removal["result"]))["state"], .string("removed"))
    do {
      try RuntimeCLI.runBootstrapTool(["inspect", "--tool", "invalid", "--output", "json"], registry: registry())
      XCTFail("invalid reference was accepted")
    } catch let error as CLIRegistryError {
      XCTAssertEqual(error.code, .invalidInput); XCTAssertEqual(error.command, "runtime.tool.inspect")
      XCTAssertEqual(error.rendering, .envelope)
    }
  }

  func testToolAndBundleShareOneCrossProcessOwnerAndSurviveSIGKILL() throws {
    for point in ["copied", "contentPublished", "recordPublished"] {
      let directory = root.appending(path: point)
      let child = Process()
      child.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckEngineCrashFixture")
      child.arguments = ["bootstrap-tool-" + point, directory.path]
      child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run()
      defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
      let ready = directory.appending(path: "ready"), deadline = Date().addingTimeInterval(20)
      while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { usleep(10_000) }
      guard FileManager.default.fileExists(atPath: ready.path) else { XCTFail("fixture did not reach \(point)"); continue }
      let shared = BootstrapBundleRegistry(root: directory.appending(path: "registry"))
      let tools = BootstrapToolRegistry(owner: shared)
      assertFailure("resourceConflict") { _ = try shared.list { _, rows in rows } }
      assertFailure("resourceConflict") { _ = try tools.list { _, rows in rows } }
      kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
      let row = try tools.register(file: directory.appending(path: "source-hdc"))
      XCTAssertEqual(try tools.register(file: directory.appending(path: "source-hdc")), row)
      XCTAssertEqual(try tools.list { _, rows in rows.count }, 1)
      XCTAssertEqual(try shared.list { _, rows in rows.count }, 0)
    }
  }

  func testCLIRegistryRejectsRootRawArgvAndEndpointForHDCRegistration() throws {
    let valid = ["runtime", "tool", "register", "--kind", "hdc", "--file", "/tmp/hdc", "--output", "json"]
    guard case .success(.dispatch(_, let leaf, _)) = CLIArgumentParser.parse(valid) else { return XCTFail("missing tool registration") }
    XCTAssertFalse(leaf.connectsToRuntime)
    for extra in [["--root", "/tmp/sdk"], ["--argv", "kill -r"], ["--socket", "/tmp/daemon"], ["--file", "/tmp/other"]] {
      if case .success = CLIArgumentParser.parse(valid + extra) { XCTFail("accepted \(extra)") }
    }
  }
}
