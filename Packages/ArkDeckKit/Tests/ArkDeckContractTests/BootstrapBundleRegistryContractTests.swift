import Darwin
import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckBootstrap
@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent
@testable import ArkDeckWorkflows

/// Isolated host filesystem fixtures. Injected signature acceptance applies
/// only to these non-executable test bytes and is never hardware evidence.
final class BootstrapBundleRegistryContractTests: XCTestCase {
  private var root: URL!
  private enum Failure: Error { case injected }
  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/bundle-registry-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  private func registry(_ name: String = "registry", fault: @escaping (String) throws -> Void = { _ in }) -> BootstrapBundleRegistry {
    .init(root: root.appending(path: name), validateBundle: { _ in }, fault: fault, nowUTC: { "2026-09-01T00:00:00Z" })
  }
  private func bundle(_ name: String = "Fixture", payload: String = "fixture content") throws -> URL {
    let url = root.appending(path: name + ".app")
    try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "fixture-1"], format: .xml, options: 0)
      .write(to: url.appending(path: "Contents/Info.plist"))
    try Data(payload.utf8).write(to: url.appending(path: "Contents/payload"))
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

  func testRegistrationSurvivesSourceDeletionAndRemovalRetainsHistoricalContent() throws {
    let source = try bundle()
    let owner = registry()
    let first = try owner.register(file: source)
    let fields = try object(first), reference = try string(fields["bundleRef"])
    XCTAssertEqual(try registry().register(file: source), first)
    XCTAssertEqual(fields["generation"], .string("1"))
    XCTAssertEqual(fields["state"], .string("available"))
    let dependency = try BootstrapBundleRegistry.ReferenceOwner(kind: .installation, id: "install-fixture")
    let stored = try owner.acquire(reference, expectedGeneration: "1", owner: dependency)
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try Data(contentsOf: stored.appending(path: "Contents/payload")), Data("fixture content".utf8))
    assertFailure("resourceConflict") { _ = try registry().remove(reference, expectedGeneration: "1") }
    try registry().release(reference, owner: dependency)
    let removed = try registry().remove(reference, expectedGeneration: "1")
    XCTAssertEqual(try object(removed)["generation"], .string("2"))
    XCTAssertEqual(try registry().remove(reference, expectedGeneration: "1"), removed)
    XCTAssertEqual(try registry().inspect(reference), removed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    assertFailure("resourceConflict") { _ = try registry().acquire(reference, expectedGeneration: "1", owner: dependency) }
    assertFailure("resourceConflict") { _ = try registry().remove(reference, expectedGeneration: "2") }
  }

  func testSuccessfulServiceInstallRetainsOnlyItsExactBundleAndUninstallReleasesIt() throws {
    let owner = registry()
    let first = try object(owner.register(file: bundle("First", payload: "first")))
    let second = try object(owner.register(file: bundle("Second", payload: "second")))
    let firstReference = try string(first["bundleRef"])
    let secondReference = try string(second["bundleRef"])
    let installation = try BootstrapBundleRegistry.ReferenceOwner(
      kind: .installation, id: "runtime-service-installation")

    _ = try owner.acquire(firstReference, expectedGeneration: "1", owner: installation)
    _ = try owner.acquire(secondReference, expectedGeneration: "1", owner: installation)
    try owner.retainOnly(secondReference, owner: installation)

    guard case .array(let firstOwners)? = try object(owner.inspect(firstReference))["references"],
      case .array(let secondOwners)? = try object(owner.inspect(secondReference))["references"]
    else { return XCTFail("bundle reference projection is malformed") }
    XCTAssertEqual(firstOwners, [])
    XCTAssertEqual(secondOwners.count, 1)
    XCTAssertNoThrow(try owner.remove(firstReference, expectedGeneration: "1"))
    assertFailure("resourceConflict") {
      _ = try owner.remove(secondReference, expectedGeneration: "1")
    }

    try owner.releaseAll(owner: installation)
    XCTAssertNoThrow(try owner.remove(secondReference, expectedGeneration: "1"))
  }

  func testQuarantineIsPreservedAndPartOfExactContentIdentity() throws {
    let source = try bundle()
    let quarantine = Data("0081;fixture;ArkDeckTests;fixture".utf8)
    XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, 0)
    let fields = try object(registry().register(file: source))
    let reference = try string(fields["bundleRef"])
    let stored = try registry().acquire(reference, expectedGeneration: "1", owner: .init(kind: .controlAction, id: "action-fixture"))
    var data = Data(count: quarantine.count)
    let count = data.withUnsafeMutableBytes { getxattr(stored.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
    XCTAssertEqual(count, quarantine.count); XCTAssertEqual(data, quarantine)
    XCTAssertEqual(removexattr(source.path, "com.apple.quarantine", 0), 0)
    let second = try object(registry().register(file: source))
    XCTAssertNotEqual(second["bundleRef"], fields["bundleRef"])
  }

  func testSourceReplacementMutationAndUntrustedBundlePublishNoRecord() throws {
    let source = try bundle()
    let racing = registry(fault: { point in
      if point == "copied" { try Data("changed content".utf8).write(to: source.appending(path: "Contents/payload")) }
    })
    assertFailure("fileIdentityChanged") { _ = try racing.register(file: source) }
    XCTAssertEqual(try registry().list { _, rows in rows }, [])
    let untrusted = BootstrapBundleRegistry(root: root.appending(path: "production-policy"))
    XCTAssertThrowsError(try untrusted.register(file: source))
    XCTAssertEqual(try untrusted.list { _, rows in rows.count }, 0)
    let source2 = try bundle("Replacement")
    let replacement = registry("replacement-store", fault: { point in
      if point == "copied" {
        try FileManager.default.moveItem(at: source2, to: source2.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: source2, withIntermediateDirectories: true)
      }
    })
    assertFailure("fileIdentityChanged") { _ = try replacement.register(file: source2) }
    let switchedDuringTrust = BootstrapBundleRegistry(root: root.appending(path: "trust-race"), validateBundle: { staged in
      let file = staged.appending(path: "Contents/payload")
      let original = try Data(contentsOf: file)
      try Data("temporarily substituted bytes".utf8).write(to: file)
      try original.write(to: file)
    })
    assertFailure("fileIdentityChanged") { _ = try switchedDuringTrust.register(file: source) }
  }

  func testLinksSpecialFilesUnsafePermissionsAndOversizedInfoAreRefused() throws {
    assertFailure("ioFailure") { _ = try registry().register(file: root.appending(path: "missing.app")) }
    let invalidPlist = try bundle("invalid-plist")
    try Data("not a property list".utf8).write(to: invalidPlist.appending(path: "Contents/Info.plist"))
    assertFailure("invalidInput") { _ = try registry().register(file: invalidPlist) }
    for type in ["symbolic", "hard", "fifo", "writable", "oversizedInfo"] {
      let source = try bundle(type)
      let file = source.appending(path: "Contents/payload")
      if type == "symbolic" { try FileManager.default.createSymbolicLink(at: source.appending(path: "Contents/link"), withDestinationURL: file) }
      if type == "hard" { XCTAssertEqual(link(file.path, source.appending(path: "Contents/link").path), 0) }
      if type == "fifo" { XCTAssertEqual(mkfifo(source.appending(path: "Contents/fifo").path, 0o600), 0) }
      if type == "writable" { XCTAssertEqual(chmod(file.path, 0o666), 0) }
      if type == "oversizedInfo" { try Data(repeating: 65, count: 65_537).write(to: source.appending(path: "Contents/Info.plist")) }
      XCTAssertThrowsError(try registry(type + "-registry").register(file: source), type)
      XCTAssertEqual(try registry(type + "-registry").list { _, rows in rows.count }, 0)
    }
    let source = try bundle("parent")
    let symbolicParent = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: symbolicParent, withDestinationURL: root)
    assertFailure("fileIdentityChanged") { _ = try registry().register(file: symbolicParent.appending(path: source.lastPathComponent)) }
  }

  func testContentAndReferenceIndexTamperingNeverBecomeEmptyOrAvailable() throws {
    let first = try object(registry().register(file: bundle()))
    let reference = try string(first["bundleRef"])
    let owner = try BootstrapBundleRegistry.ReferenceOwner(kind: .job, id: "job-fixture")
    let stored = try registry().acquire(reference, expectedGeneration: "1", owner: owner)
    try Data("tampered".utf8).write(to: stored.appending(path: "Contents/payload"))
    assertFailure("recordUnreadable") { _ = try registry().remove(reference, expectedGeneration: "1") }
    assertFailure("recordUnreadable") { _ = try registry().inspect(reference) }
    let index = root.appending(path: "registry/bundles.json")
    try Data("{\"schemaVersion\":\"arkdeck.bootstrap-bundles/1\",\"records\":[],\"records\":[]}".utf8).write(to: index)
    assertFailure("recordUnreadable") { _ = try registry().list { _, rows in rows } }
    assertFailure("recordUnreadable") { _ = try registry().remove(reference, expectedGeneration: "1") }
    try FileManager.default.removeItem(at: index)
    assertFailure("recordUnreadable") { _ = try registry().list { _, rows in rows } }
    assertFailure("recordUnreadable") { _ = try registry().register(file: bundle("after-index-loss")) }
  }

  func testImmutableSnapshotContinuationDoesNotChangeAfterRemoval() throws {
    for value in ["one", "two", "three"] { _ = try registry().register(file: bundle(value, payload: value)) }
    func page(_ cursor: String?) throws -> [String: JSONValue] {
      try object(registry().list { directory, items in
        try RuntimeSnapshotPager(directory: directory).page(method: "runtime.bundle.list", filters: [:], order: "bundleRef:asc",
          pageSize: 1, cursor: cursor, items: { items })
      })
    }
    let first = try page(nil), cursor = try string(first["nextCursor"])
    let continuation = try page(cursor)
    guard case .array(let items)? = continuation["items"] else { throw Failure.injected }
    let removed = try string(object(XCTUnwrap(items.first))["bundleRef"])
    _ = try registry().remove(removed, expectedGeneration: "1")
    XCTAssertEqual(try page(cursor), continuation)
    XCTAssertEqual(try object(registry().inspect(removed))["state"], .string("removed"))
    assertFailure("invalidCursor") {
      _ = try registry().list { directory, items in
        try RuntimeSnapshotPager(directory: directory).page(method: "runtime.bundle.list", filters: [:], order: "bundleRef:asc",
          pageSize: 2, cursor: cursor, items: { items })
      }
    }
  }

  func testCrossProcessOwnerLockAndSIGKILLRecoveryAtPublicationBoundaries() throws {
    for point in ["copied", "contentPublished", "recordPublished"] {
      let directory = root.appending(path: point)
      let child = Process()
      child.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckEngineCrashFixture")
      child.arguments = ["bootstrap-bundle-" + point, directory.path]
      child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run()
      defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
      let ready = directory.appending(path: "ready"), deadline = Date().addingTimeInterval(15)
      while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { usleep(10_000) }
      guard FileManager.default.fileExists(atPath: ready.path) else { XCTFail("crash fixture did not reach \(point)"); continue }
      let owner = BootstrapBundleRegistry(root: directory.appending(path: "registry"), validateBundle: { _ in })
      assertFailure("resourceConflict") { _ = try owner.list { _, rows in rows } }
      kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
      let first = try owner.register(file: directory.appending(path: "Fixture.app"))
      XCTAssertEqual(try owner.register(file: directory.appending(path: "Fixture.app")), first)
      XCTAssertEqual(try owner.list { _, rows in rows.count }, 1)
      let reference = try string(object(first)["bundleRef"])
      _ = try owner.remove(reference, expectedGeneration: "1")
      XCTAssertEqual(try object(owner.inspect(reference))["state"], .string("removed"))
    }
  }

  func testCLIRegistryExposesOnlyTypedBootstrapInputsAndNoRuntimeEndpoint() throws {
    for argv in [
      ["runtime", "bundle", "register", "--kind", "daemon-bundle", "--file", "/tmp/helper.app", "--output", "json"],
      ["runtime", "bundle", "list", "--page-size", "5", "--output", "json"],
      ["runtime", "bundle", "inspect", "--bundle", "bundle:sha256:" + String(repeating: "a", count: 64)],
      ["runtime", "bundle", "remove", "--bundle", "bundle:sha256:" + String(repeating: "a", count: 64), "--expected-generation", "1"],
    ] {
      guard case .success(.dispatch(_, let leaf, _)) = CLIArgumentParser.parse(argv) else { XCTFail("registry rejected \(argv)"); continue }
      XCTAssertFalse(leaf.connectsToRuntime)
      if case .success = CLIArgumentParser.parse(argv + ["--socket", "/tmp/ignored.sock"]) { XCTFail("bootstrap accepted daemon endpoint") }
      if case .success = CLIArgumentParser.parse(argv + ["--root", "/tmp/ignored"]) { XCTFail("bundle accepted SDK root schema") }
    }
  }

  func testCLIHandlerEmitsOneVersionedDocumentForTheRegisteredOwner() throws {
    func invoke(_ args: [String]) throws -> [String: JSONValue] {
      let output = root.appending(path: "stdout-\(UUID()).json")
      let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard fd >= 0 else { throw Failure.injected }
      defer { close(fd) }
      fflush(stdout)
      let original = dup(STDOUT_FILENO)
      guard original >= 0, dup2(fd, STDOUT_FILENO) >= 0 else { throw Failure.injected }
      defer { fflush(stdout); _ = dup2(original, STDOUT_FILENO); close(original) }
      try RuntimeCLI.runBootstrapBundle(args + ["--output", "json", "--control-request-id", "bundle-test"], registry: registry())
      fflush(stdout)
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: output))
      return try object(value)
    }
    let registered = try invoke(["register", "--kind", "daemon-bundle", "--file", bundle().path])
    XCTAssertEqual(registered["schemaVersion"], .string("arkdeck.cli.result/1"))
    XCTAssertEqual(registered["command"], .string("runtime.bundle.register")); XCTAssertEqual(registered["ok"], .bool(true))
    let row = try object(XCTUnwrap(registered["result"])), reference = try string(row["bundleRef"])
    let inspected = try invoke(["inspect", "--bundle", reference])
    XCTAssertEqual(inspected["result"], registered["result"])
    let listed = try invoke(["list", "--page-size", "1"])
    XCTAssertEqual(try object(XCTUnwrap(listed["result"]))["items"], .array([.object(row)]))
    let removed = try invoke(["remove", "--bundle", reference, "--expected-generation", "1"])
    XCTAssertEqual(try object(XCTUnwrap(removed["result"]))["state"], .string("removed"))
    do {
      try RuntimeCLI.runBootstrapBundle(["inspect", "--bundle", "invalid", "--output", "json"], registry: registry())
      XCTFail("invalid reference was accepted")
    } catch let error as CLIRegistryError {
      XCTAssertEqual(error.code, .invalidInput); XCTAssertEqual(error.command, "runtime.bundle.inspect")
      XCTAssertEqual(error.rendering, .envelope)
    }
  }
}
