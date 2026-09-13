// Builds synthetic host fixtures with pinned ArkTrace's actual owner and
// Codable metadata implementation. The database is fixture bytes, not a parsed
// trace, and no parser executable, device or installed cache is accessed.
import ArkTraceCore
import CryptoKit
import Foundation
@testable import ArkTraceRuntime

@main
struct TraceMaintenanceFixture {
  static func directory(_ path: URL) throws {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }
  static func write(_ data: Data, _ path: URL) throws {
    try data.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }
  static func json(_ value: Any, _ path: URL) throws {
    try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), path)
  }
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func inventory(_ value: TraceCacheInventory) -> [String: Any] {
    ["entryCount": value.entryCount, "totalByteCount": String(value.totalByteCount),
     "activeEntryCount": value.activeEntryCount,
     "inactiveEntryCount": value.entryCount - value.activeEntryCount]
  }
  static func seed(_ root: URL) async throws -> TraceCacheMaintenanceService {
    let parent = root.appending(path: "trace-cache", directoryHint: .isDirectory)
    let cache = parent.appending(path: "traces", directoryHint: .isDirectory)
    let staging = parent.appending(path: "staging", directoryHint: .isDirectory)
    try directory(cache)
    try directory(staging)
    let bytes = Data("synthetic derived database".utf8)
    let source = Data("synthetic original Trace Artifact".utf8)
    try write(source, root.appending(path: "original.htrace"))
    let trace = hash(source), parserHash = String(repeating: "b", count: 64)
    let key = try TraceCacheKey(traceSHA256: trace, parserBinarySHA256: parserHash,
      upstreamRevision: "fixture", schemaAdapterVersion: "fixture", indexSchemaVersion: 1)
    let parser = TraceParserIdentity(name: "fixture", reportedVersion: "fixture",
      binarySHA256: parserHash, upstreamRepository: "fixture", upstreamRevision: "fixture",
      architecture: "fixture", adapterVersion: "fixture", buildRecipeVersion: "fixture")
    let preparation = TraceDatabasePreparationResult(schemaAdapterVersion: "fixture",
      schemaFingerprint: "fixture", indexVersion: 1, upstreamDatabaseSHA256: hash(bytes),
      upstreamDatabaseByteCount: Int64(bytes.count))
    let date = Date(timeIntervalSince1970: 1_788_177_600)
    let metadata = TraceCacheMetadata(cacheKey: key, parser: parser, sourceSHA256: trace,
      sourceByteCount: Int64(source.count), databasePreparation: preparation,
      databaseByteCount: Int64(bytes.count), createdAt: date, lastAccessedAt: date)
    var owner: TraceOwnedDirectory? = try await TraceContentAddressedCache.createOwnedDirectory(
      root: cache.appending(path: ".staging", directoryHint: .isDirectory), prefix: "entry-", recoveryRoot: cache)
    let held = owner!
    try write(bytes, held.url.appending(path: "database.sqlite"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try write(encoder.encode(metadata), held.url.appending(path: "metadata.json"))
    let traceRoot = cache.appending(path: trace, directoryHint: .isDirectory)
    try directory(traceRoot)
    let entry = traceRoot.appending(path: key.parserKey, directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: held.url, to: entry)
    try TraceContentAddressedCache.updateOwnerEvidence(for: held, state: .ready)
    let lock = hash(Data("\(trace):\(key.parserKey)".utf8))
    for (name, suffix) in [(".locks", "lock"), (".leases", "lease")] {
      let parent = cache.appending(path: name, directoryHint: .isDirectory)
      try directory(parent)
      try write(Data(), parent.appending(path: "\(lock).\(suffix)"))
    }
    // The outer seed scope returns before inspection, releasing this native
    // owner's lease without changing the evidence it produced.
    owner = nil
    var stale: TraceOwnedDirectory? = try await TraceContentAddressedCache.createOwnedDirectory(
      root: staging, prefix: "session-")
    try write(Data("private residual".utf8), stale!.url.appending(path: "private.sqlite"))
    stale = nil
    return try TraceCacheMaintenanceService(cacheDirectory: cache.standardizedFileURL,
      stagingDirectory: staging.standardizedFileURL)
  }
  static func main() async throws {
    guard CommandLine.arguments.count == 3 else { fatalError("mode and fixture root are required") }
    let mode = CommandLine.arguments[1]
    let argument = CommandLine.arguments[2]
    guard argument.hasPrefix("/private/tmp/") else { fatalError("fixture must be under /private/tmp") }
    let root = URL(filePath: argument, directoryHint: .isDirectory).standardizedFileURL
    let rustRoot = root.appending(path: "rust", directoryHint: .isDirectory)
    let swiftRoot = root.appending(path: "swift", directoryHint: .isDirectory)
    if mode == "seed" {
      guard !FileManager.default.fileExists(atPath: root.path) else { fatalError("fixture must be new") }
      try directory(rustRoot)
      try directory(swiftRoot)
      _ = try await seed(rustRoot)
      _ = try await seed(swiftRoot)
      return
    }
    // A separate process consumes the native owner records, so no producer
    // scope or async task can retain an owner lease during maintenance.
    guard mode == "report", FileManager.default.fileExists(atPath: root.path) else {
      fatalError("report requires the seeded fixture")
    }
    func service(_ root: URL) throws -> TraceCacheMaintenanceService {
      try TraceCacheMaintenanceService(
        cacheDirectory: root.appending(path: "trace-cache/traces", directoryHint: .isDirectory).standardizedFileURL,
        stagingDirectory: root.appending(path: "trace-cache/staging", directoryHint: .isDirectory).standardizedFileURL)
    }
    let rust = try service(rustRoot), swift = try service(swiftRoot)
    let before = try await rust.inventory()
    guard before.entryCount == 1, before.activeEntryCount == 0 else { fatalError("native owner still active") }
    let cacheRoot = swiftRoot.appending(path: "trace-cache/traces", directoryHint: .isDirectory)
      .resolvingSymlinksInPath().standardizedFileURL
    let owners = cacheRoot.appending(path: ".staging/.owners", directoryHint: .isDirectory)
    var diagnostics = [[String: Any]]()
    for evidence in try FileManager.default.contentsOfDirectory(at: owners, includingPropertiesForKeys: nil)
      where evidence.pathExtension == "json" {
      let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as! [String: Any]
      let relative = fields["relativePath"] as! String
      var target = cacheRoot.standardizedFileURL
      for component in relative.split(separator: "/") { target.append(path: String(component)) }
      target = target.standardizedFileURL
      let entry = cacheRoot.appending(path: relative, directoryHint: .isDirectory).standardizedFileURL
      diagnostics.append(["relativePath":relative, "target":target.absoluteString,
        "resolvedTarget":target.resolvingSymlinksInPath().standardizedFileURL.absoluteString,
        "entry":entry.absoluteString, "targetEqualsEntry":target == entry,
        "targetIsResolved":target.resolvingSymlinksInPath().standardizedFileURL == target])
    }
    try json(diagnostics, root.appending(path: "native-owner-diagnostics.json"))
    let report = try await swift.purgeUnused()
    try json(["schemaVersion":"arkdeck.trace-cache-purge/1", "before":inventory(report.before),
      "after":inventory(report.after), "removedEntryCount":report.removedEntryCount,
      "skippedActiveEntryCount":report.skippedActiveEntryCount,
      "recoveredPrivateDirectoryCount":report.recoveredPrivateDirectoryCount,
      "removedOrphanOwnerMarkerCount":report.removedOrphanOwnerMarkerCount,
      "purgeScope":"inactiveDerivedDatabases", "originalTraceArtifactRemovalCount":0],
      root.appending(path: "swift-expected-purge.json"))
    guard report.removedEntryCount == 1, report.recoveredPrivateDirectoryCount == 1 else {
      fatalError("native fixture was not reclaimed; exact report retained")
    }
    try write(Data("native ArkTrace owner and metadata; synthetic host database; no device evidence\n".utf8), root.appending(path: "fixture-kind"))
    print("PASS: native owner/metadata fixture ready; paired Swift purge removed one derived entry and one private residual")
  }
}
