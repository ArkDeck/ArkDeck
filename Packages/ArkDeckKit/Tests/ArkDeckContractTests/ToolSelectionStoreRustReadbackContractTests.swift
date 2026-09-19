// The production Swift tool-selection store reading what the Rust store
// wrote (TASK-XPA-012): `rust/tests/fixtures/tool-selection-store-rust`, the
// records `arkdeck-hoststore`'s `rust_written_records_are_the_checked_in_ones`
// writes with identities and instants of its own, byte for byte. Swift lists
// them, finds each its own canonical bytes, projects them as Rust did, and
// carries two of them further through its own transitions and compare-and-set
// replacement, as a Swift owner inheriting a Rust owner's directory would.
//
// Host-local only: no device, no daemon, no HDC server.
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class ToolSelectionStoreRustReadbackContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let written = repository.appending(
    path: "rust/tests/fixtures/tool-selection-store-rust", directoryHint: .isDirectory)
  /// 2026-09-02T00:00:00Z; the Rust timelines start n × 1000 s later.
  private static let start = Date(timeIntervalSince1970: 1_788_307_200)
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-selection-rust-readback-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testTheProductionStoreReadsAndContinuesTheRustWrittenRecords() throws {
    // The store opens only an owner-private directory of owner-private files.
    let records = root.appending(path: "records", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: records, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let source = Self.written.appending(path: "records")
    for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
      let target = records.appending(path: name)
      try FileManager.default.copyItem(at: source.appending(path: name), to: target)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    let store = try RuntimeToolSelectionControlActionStore(directory: records)
    let listed = try store.list()
    XCTAssertEqual(
      listed.map(\.intent.actionRequestID),
      ["rust-observing", "rust-challenged", "rust-approved", "rust-succeeded", "rust-expired"])
    for record in listed {
      let name =
        "action-" + SHA256Hex.string(of: Data(record.intent.actionRequestID.utf8)) + ".json"
      XCTAssertEqual(
        try PortableCanonicalJSON.canonicalBytes(.object(record.value)),
        try Data(contentsOf: source.appending(path: name)),
        "\(record.intent.actionRequestID) is not its own canonical bytes")
    }
    let projections = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: Self.written.appending(path: "projections.json")))
    XCTAssertEqual(projections, .array(listed.map(\.projection)))

    // Swift answers the Rust-issued challenge, and prepares the approval Rust
    // recorded: both replace the Rust records as their next generations.
    let challenged = try XCTUnwrap(try store.load(requestID: "rust-challenged"))
    let answered = try challenged.recordingInteractiveApproval(
      response: "ARKDECK-RUST00001", now: Self.start.addingTimeInterval(1000 + 50))
    try store.replace(answered, expectedGeneration: challenged.generation)
    let approved = try XCTUnwrap(try store.load(requestID: "rust-approved"))
    let prepared = try approved.prepared(now: Self.start.addingTimeInterval(2000 + 50))
    try store.replace(prepared, expectedGeneration: approved.generation)
    XCTAssertEqual(try store.load(requestID: "rust-challenged")?.state, "approvalRecorded")
    XCTAssertEqual(try store.load(requestID: "rust-approved")?.state, "dispatchPrepared")
    // A stale Rust generation is refused, as any other.
    XCTAssertThrowsError(try store.replace(answered, expectedGeneration: challenged.generation))
  }
}
