import ArkDeckTraceAdapter
import CryptoKit
import Darwin
import Foundation
import XCTest

/// Actual Swift/Rust maintenance inventory over the same isolated filesystem.
/// The fixture database is never executed or presented as a real parsed trace.
final class HostStoreTraceShadowTests: XCTestCase {
  private static let oracleBinarySHA256: String? = {
    guard let file = Bundle(for: HostStoreTraceShadowTests.self).executableURL,
      let bytes = try? Data(contentsOf: file) else { return nil }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }()
  private var root: URL!
  private var cache: URL!
  private var binary: URL!
  private let traceName = String(repeating: "a", count: 64)
  private let parserName = String(repeating: "b", count: 64)

  override func setUpWithError() throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_HOSTSTORE_SHADOW_BINARY"] else {
      throw XCTSkip("run rust/scripts/hoststore-shadow.py for cross-language inventory")
    }
    binary = URL(filePath: path)
    root = URL(filePath: "/private/tmp/arkdeck-trace-shadow-\(UUID().uuidString.lowercased())").standardizedFileURL
    try directory(root)
    root = root.standardizedFileURL
    cache = ArkDeckTraceConfiguration.cacheDirectories(cachesDirectory: root).cache
    try directory(cache)
    try Data("original trace fixture".utf8).write(to: root.appending(path: "original.htrace"))
  }

  override func tearDownWithError() throws {
    if let root { try FileManager.default.removeItem(at: root) }
  }

  func testTraceInventoryEmptyUnaccountedReadyAndContended() async throws {
    let service = try ArkDeckTraceCacheMaintenanceService(cachesDirectory: root)
    try await compare("trace-empty", service: service)
    let entry = cache.appending(path: traceName).appending(path: parserName)
    try directory(entry)
    try file(Data([1, 2, 3]), at: entry.appending(path: "database.sqlite"))
    try await compare("trace-unaccounted", service: service)
    let metadata = try JSONSerialization.data(withJSONObject: metadata(), options: [.sortedKeys])
    try file(metadata, at: entry.appending(path: "metadata.json"))
    let id = hash(Data("\(traceName):\(parserName)".utf8))
    let locks = cache.appending(path: ".locks"), leases = cache.appending(path: ".leases")
    try directory(locks); try directory(leases)
    let key = locks.appending(path: id + ".lock"), lease = leases.appending(path: id + ".lease")
    try file(Data(), at: key); try file(Data(), at: lease)
    try await compare("trace-ready-inactive", service: service)
    for (name, path) in [("trace-key-contended", key), ("trace-lease-contended", lease)] {
      let held = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      XCTAssertGreaterThanOrEqual(held, 0)
      guard held >= 0 else { return }
      defer { Darwin.close(held) }
      XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
      try await compare(name, service: service)
      XCTAssertEqual(flock(held, LOCK_UN), 0)
    }
    XCTAssertEqual(try Data(contentsOf: root.appending(path: "original.htrace")), Data("original trace fixture".utf8))
  }

  func testTraceInventoryRejectsEntrySymlinkAndEnumerationOverflow() async throws {
    let service = try ArkDeckTraceCacheMaintenanceService(cachesDirectory: root)
    let entry = cache.appending(path: traceName).appending(path: parserName)
    try directory(entry)
    let link = entry.appending(path: "symlink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "original.htrace"))
    try await refuse("trace-entry-symlink", service: service)
    try FileManager.default.removeItem(at: link)
    for index in 0..<17 { try file(Data([0]), at: entry.appending(path: "file-\(index)")) }
    try await refuse("trace-entry-overflow", service: service)
  }

  func testTraceMetadataDateProjectionMatchesActualDecoder() async throws {
    let service = try ArkDeckTraceCacheMaintenanceService(cachesDirectory: root)
    let entry = cache.appending(path: traceName).appending(path: parserName)
    try directory(entry)
    try file(Data([1, 2, 3]), at: entry.appending(path: "database.sqlite"))
    let id = hash(Data("\(traceName):\(parserName)".utf8))
    for (folder, suffix) in [(".locks", ".lock"), (".leases", ".lease")] {
      let path = cache.appending(path: folder)
      try directory(path)
      try file(Data(), at: path.appending(path: id + suffix))
    }
    // Inventory counts undecodable metadata as active/unaccounted, while the
    // original payload remains measurable. It does not refuse the whole scan.
    let dates = ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00.123456789Z",
      "2026-01-01T00:00:00Ztail", "2026-2-31T1:2:3z", "0-1-1T0:0:0Z",
      "506714-1-1T0:0:0Z", "2026-1-1T24:00:01Z", "2026-1-1T0:0:61Z",
      "2026-1-1T0:0:0GMT+1:2:3", "2026-1-1T0:0:0-18", "2026-1-1T0:0:0+01:00:",
      "", "invalid", "2026-1-1T0:0:0.1234567890Z", "2026-1-1T0:0:0+18:00:01",
      "506715-1-1T0:0:0Z", "2026-1-1T0:0:2147483648Z", "2026-1-1t0:0:0Z"]
    for field in ["createdAt", "lastAccessedAt"] {
      for (index, date) in dates.enumerated() {
        var document = metadata()
        document[field] = date
        try file(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), at: entry.appending(path: "metadata.json"))
        try await compare("trace-date-" + field + "-" + String(index), service: service)
      }
    }
  }

  private func compare(_ name: String, service: ArkDeckTraceCacheMaintenanceService) async throws {
    let before = try snapshot()
    let swift = try await service.inventory()
    let expected: [String: Any] = [
      "schemaVersion": "arkdeck.trace-cache-status/1", "entryCount": swift.entryCount,
      "totalByteCount": String(swift.totalByteCount), "activeEntryCount": swift.activeEntryCount,
      "inactiveEntryCount": max(0, swift.entryCount - swift.activeEntryCount),
      "purgeScope": "inactiveDerivedDatabases",
    ]
    let bytes = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .withoutEscapingSlashes])
    let result = try rust()
    XCTAssertEqual(result.status, 0, name)
    XCTAssertEqual(result.output, bytes + Data([0x0A]), name)
    XCTAssertEqual(try snapshot(), before, "inventory must not mutate any cache file or lock")
    try record(name, input: before, output: bytes, outcome: "equal")
  }

  private func refuse(_ name: String, service: ArkDeckTraceCacheMaintenanceService) async throws {
    let before = try snapshot()
    do { _ = try await service.inventory(); XCTFail("Swift accepted unsafe inventory") }
    catch { /* Expected conservative refusal, with fixture bytes retained. */ }
    let result = try rust()
    XCTAssertEqual(result.status, 65)
    XCTAssertTrue(result.output.isEmpty)
    XCTAssertEqual(try snapshot(), before)
    try record(name, input: before, output: Data(), outcome: "refused")
  }

  private func rust() throws -> (status: Int32, output: Data) {
    let process = Process(), stdout = Pipe(), stderr = Pipe()
    // Foundation standardizes /private/tmp to /tmp on this host. The Rust
    // descriptor boundary takes a physical root, so resolve the fixture once.
    let resolved = try XCTUnwrap(realpath(cache.path, nil))
    defer { free(resolved) }
    process.executableURL = binary; process.arguments = ["trace-cache", String(cString: resolved)]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout; process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
  }

  private func directory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
  private func file(_ data: Data, at url: URL) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

  private func snapshot() throws -> Data {
    let paths = try FileManager.default.subpathsOfDirectory(atPath: cache.path).sorted()
    var values: [[String: String]] = []
    for path in paths {
      let url = cache.appending(path: path)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let type = try XCTUnwrap(attributes[.type] as? FileAttributeType)
      var value = ["path": path, "type": type.rawValue]
      if type == .typeRegular { value["sha256"] = hash(try Data(contentsOf: url)) }
      if type == .typeSymbolicLink { value["link"] = try FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
      values.append(value)
    }
    return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  private func record(_ name: String, input: Data, output: Data, outcome: String) throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_HOSTSTORE_SHADOW_RESULTS"] else { return }
    let report = ["case": name, "store": "trace-cache", "outcome": outcome,
                  "inputSHA256": hash(input), "projectionSHA256": hash(output),
                  "oracleBinarySHA256": try XCTUnwrap(Self.oracleBinarySHA256)]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try bytes.write(to: URL(filePath: path).appending(path: name + ".json"), options: .withoutOverwriting)
  }

  private func metadata() -> [String: Any] {
    [
      "formatVersion": 1,
      "cacheKey": ["traceSHA256": traceName, "parserBinarySHA256": parserName,
                   "upstreamRevision": "fixture", "schemaAdapterVersion": "fixture", "indexSchemaVersion": 1, "parserKey": parserName],
      "parser": ["name": "fixture", "reportedVersion": "fixture", "binarySHA256": parserName,
                 "upstreamRepository": "fixture", "upstreamRevision": "fixture", "architecture": "fixture",
                 "adapterVersion": "fixture", "buildRecipeVersion": "fixture"],
      "traceSHA256": traceName, "sourceSHA256": traceName, "sourceByteCount": 3,
      "schemaFingerprint": "fixture", "schemaAdapterVersion": "fixture", "indexSchemaVersion": 1,
      "databasePreparation": ["schemaAdapterVersion": "fixture", "schemaFingerprint": "fixture", "indexVersion": 1,
                              "upstreamDatabaseSHA256": traceName, "upstreamDatabaseByteCount": 3],
      "databaseByteCount": 3, "createdAt": "2026-09-10T00:00:00Z", "lastAccessedAt": "2026-09-10T00:00:00Z",
    ]
  }
}
