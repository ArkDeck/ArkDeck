// Shared Swift oracle for the capability ledger's only outcome rewrite
// (TASK-XPA-014, recovery port slice 2).
//
// `RuntimeCapabilityStore.recordOutcome` is a carrier of ADR-0009 decision 4
// in the CHG-2026-074 decision package (§2): outcomes are appended, never
// replaced, and the one permitted change is `resolvesUnknown` — an
// `outcomeUnknown` use settled by a later readback as `confirmed` or
// `safeToReflash`; anything else is `outcomeConflict`. The maintainer ruled on
// 2026-09-19 that Rust ports it unchanged.
//
// This oracle leaves, in the layout of the M2 oracles' stores, a capability
// store where a use went `outcomeUnknown` and was then resolved `confirmed`
// (and the capability used again), and another resolved `safeToReflash` (and
// used again, left pending), so the Rust store's replay of every ledger event
// reproduces the two-outcome uses byte for byte. It also records every
// refused change with Swift's refusal, and that a refusal writes nothing.
//
// Only test-owned temporary stores hold these synthetic capabilities. Record a
// new oracle with `ARKDECK_RUST_CAPABILITY_RESOLVE_RECORD=/private/tmp/<new
// directory>`; otherwise the checked-in oracle must match byte for byte.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class CapabilityResolveOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capability-resolve", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_CAPABILITY_RESOLVE_RECORD"
  private static let confirmedID = "CAP-RT-RESOLVE-CONFIRMED"
  private static let safeID = "CAP-RT-RESOLVE-SAFE"

  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-capability-resolve-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  private static func capability(_ id: String) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: id,
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 3,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#800 deadbeef"))
  }

  private static func query() -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: "debug.hap", operationVersion: 1, effect: .deviceMutation,
      targetStableIdentitySHA256: String(repeating: "a", count: 64),
      targetBindingRevision: 7, planDigest: String(repeating: "b", count: 64), inputs: [:])
  }

  func testSwiftResolvesUnknownOutcomesAndRefusesEveryOtherChange() async throws {
    let directory = scratch.appending(path: "store/capabilities", directoryHint: .isDirectory)
    let store = try RuntimeCapabilityStore(directoryURL: directory)
    try await store.install(try Self.capability(Self.confirmedID))
    try await store.install(try Self.capability(Self.safeID))

    func consume(_ id: String, _ reservation: String, _ job: String, at time: String)
      async throws
    {
      _ = try await store.consume(
        capabilityID: id, reservationID: reservation, jobID: job, query: Self.query(),
        nowUTC: time)
    }
    func settle(
      _ id: String, _ reservation: String, _ job: String,
      _ outcome: RuntimeCapabilityUseOutcome, _ state: String, at time: String
    ) async throws {
      try await store.recordOutcome(
        capabilityID: id, reservationID: reservation, jobID: job, outcome: outcome,
        terminalState: state, atUTC: time)
    }

    // A use left unknown, then resolved confirmed by a readback, then the
    // capability used again, linked to the resolution.
    try await consume(Self.confirmedID, "res-c1", "job-c1", at: "2026-07-15T00:00:00Z")
    try await settle(
      Self.confirmedID, "res-c1", "job-c1", .outcomeUnknown, "waitingForRecovery",
      at: "2026-07-15T00:01:00Z")
    try await settle(
      Self.confirmedID, "res-c1", "job-c1", .confirmed, "failed", at: "2026-07-15T00:02:00Z")
    try await consume(Self.confirmedID, "res-c2", "job-c2", at: "2026-07-15T00:03:00Z")
    try await settle(
      Self.confirmedID, "res-c2", "job-c2", .confirmed, "succeeded", at: "2026-07-15T00:04:00Z")

    // A use left unknown, then proven not executed (safe to reflash), then
    // the capability used again and left pending.
    try await consume(Self.safeID, "res-s1", "job-s1", at: "2026-07-16T00:00:00Z")
    try await settle(
      Self.safeID, "res-s1", "job-s1", .outcomeUnknown, "waitingForRecovery",
      at: "2026-07-16T00:01:00Z")
    try await settle(
      Self.safeID, "res-s1", "job-s1", .safeToReflash, "failed", at: "2026-07-16T00:02:00Z")
    try await consume(Self.safeID, "res-s2", "job-s2", at: "2026-07-16T00:03:00Z")

    // Every other change is refused and writes nothing.
    let checkpointURL = directory.appending(path: "runtime-capabilities.json")
    let ledgerURL = directory.appending(path: "runtime-capabilities.ledger")
    let checkpoint = try Data(contentsOf: checkpointURL)
    let ledger = try Data(contentsOf: ledgerURL)
    let refusals:
      [(name: String, id: String, reservation: String, job: String,
        outcome: RuntimeCapabilityUseOutcome, state: String)] = [
        ("resolvedConfirmedToUnknown", Self.confirmedID, "res-c1", "job-c1", .outcomeUnknown,
          "waitingForRecovery"),
        ("resolvedConfirmedToSafe", Self.confirmedID, "res-c1", "job-c1", .safeToReflash, "failed"),
        ("confirmedToUnknown", Self.confirmedID, "res-c2", "job-c2", .outcomeUnknown,
          "waitingForRecovery"),
        ("safeToConfirmed", Self.safeID, "res-s1", "job-s1", .confirmed, "succeeded"),
        ("safeToUnknown", Self.safeID, "res-s1", "job-s1", .outcomeUnknown, "waitingForRecovery"),
        ("confirmedOtherTerminal", Self.confirmedID, "res-c2", "job-c2", .confirmed, "failed"),
      ]
    var cases: [JSONValue] = []
    for refusal in refusals {
      do {
        try await settle(
          refusal.id, refusal.reservation, refusal.job, refusal.outcome, refusal.state,
          at: "2026-07-17T00:00:00Z")
        XCTFail("\(refusal.name) must be refused")
      } catch let error as RuntimeCapabilityStoreError {
        guard case .outcomeConflict = error else {
          return XCTFail("\(refusal.name): \(error)")
        }
        cases.append(
          .object([
            "name": .string(refusal.name), "capabilityID": .string(refusal.id),
            "reservationID": .string(refusal.reservation), "jobID": .string(refusal.job),
            "outcome": .string(refusal.outcome.rawValue), "terminalState": .string(refusal.state),
            "recordedAtUTC": .string("2026-07-17T00:00:00Z"),
            "refused": .string("\(error)"),
          ]))
      }
    }
    // The same resolution again, at another time, is accepted and writes nothing.
    try await settle(
      Self.safeID, "res-s1", "job-s1", .safeToReflash, "failed", at: "2026-07-18T00:00:00Z")
    XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpoint)
    XCTAssertEqual(try Data(contentsOf: ledgerURL), ledger)

    let inspected = try await store.inspect(capabilityID: Self.confirmedID)
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(
      status.lineage.first?.outcomeHistory.map(\.outcome), [.outcomeUnknown, .confirmed])
    XCTAssertTrue(status.lineageAllowsNewExecution)

    // The store's files, and its entries with their kinds and modes in the
    // M2 oracles' `tree.json` layout, which the Rust replay compares.
    var files: [String: Data] = [:]
    var tree: [JSONValue] = []
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
      let url = directory.appending(path: name)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
      tree.append(
        .object([
          "path": .string("store/capabilities/\(name)"), "kind": .string("file"),
          "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
        ]))
      files["store/capabilities/\(name)"] = try Data(contentsOf: url)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["tree.json"] = try encoder.encode(JSONValue.array(tree)) + Data("\n".utf8)
    files["cases.json"] = try encoder.encode(JSONValue.array(cases)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "CapabilityResolveOracleContractTests.testSwiftResolvesUnknownOutcomesAndRefusesEveryOtherChange"),
          "store": .string("RuntimeCapabilityStore (a test-owned temporary directory)"),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
