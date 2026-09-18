// Shared Swift oracle for the Rust capability reader (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `capability.list` and `capability.inspect`: the oracle
/// `rust/crates/arkdeck-hoststore/tests/capability_read.rs` replays against
/// the Rust capability reader.
///
/// Each scenario is one capability store. Most are written by the Swift
/// `RuntimeCapabilityStore` through its public API: installs, uses, every use
/// outcome, a revocation, and more appended events than
/// `checkpointEveryEvents`, so the checkpoint is rewritten while the ledger
/// keeps growing. The others are such a store with one defect each: a missing
/// or linked checkpoint, a linked ledger, malformed or duplicate JSON, a
/// member the current shape lacks, a broken invariant, account or digest, an
/// undecodable, unknown or unreplayable ledger event, or a torn final append.
/// A store opened afresh over the scenario's directory answers every read
/// through the control plane. The oracle keeps each store's files as the
/// reads found them, the kind and mode of every entry before and after the
/// reads, and every answer, with the store's directory spelled `<store>`
/// where an answer names it.
///
/// The capabilities are synthetic: they exist only in this test's temporary
/// directories and authorize nothing. Record a new oracle with
/// `ARKDECK_RUST_CAPABILITY_READ_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CapabilityReadOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capability-read", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let storeLabel = "<store>"
  private static let checkpointName = "runtime-capabilities.json"
  private static let ledgerName = "runtime-capabilities.ledger"

  private static let deviceA = String(repeating: "a", count: 64)
  private static let deviceC = String(repeating: "c", count: 64)
  private static let workspace = String(repeating: "e", count: 64)
  private static let fileScopes = String(repeating: "f", count: 64)

  private struct Read {
    let method: String
    let params: [String: JSONValue]
  }

  private struct Scenario {
    let name: String
    let reads: [Read]
  }

  func testSwiftReadsTheSharedCapabilityOracle() async throws {
    let manager = FileManager.default
    let run = manager.temporaryDirectory.appending(
      path: "arkdeck-capability-read-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)
    let stores = run.appending(path: "stores", directoryHint: .isDirectory)
    try manager.createDirectory(
      at: stores, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: run) }

    var files: [String: Data] = [:]
    var cases: [JSONValue] = []
    var trees: [String: JSONValue] = [:]
    for scenario in try await Self.scenarios(in: stores) {
      let directory = stores.appending(path: scenario.name, directoryHint: .isDirectory)
      let before = try Self.entries(of: directory)
      for (name, data) in before.contents {
        files["stores/\(scenario.name)/\(name)"] = data
      }
      let handler = try Self.handler(
        over: directory,
        engineState: run.appending(path: "engines/\(scenario.name)", directoryHint: .isDirectory))
      var exchanges: [JSONValue] = []
      for read in scenario.reads {
        let response = try await Self.send(handler, read.method, read.params)
        exchanges.append(
          .object([
            "method": .string(read.method), "params": .object(read.params),
            "response": Self.labelled(response, directory: directory),
          ]))
      }
      let after = try Self.entries(of: directory)
      // A read writes no store document: every file the reads found is
      // byte-identical afterwards, and at most the lock file is new.
      for (name, data) in before.contents {
        XCTAssertEqual(after.contents[name], data, "\(scenario.name)/\(name)")
      }
      XCTAssertTrue(
        Set(after.contents.keys).subtracting(before.contents.keys)
          .isSubset(of: [".runtime-capabilities.lock"]), scenario.name)
      trees[scenario.name] = .object(["before": before.tree, "after": after.tree])
      cases.append(
        .object(["scenario": .string(scenario.name), "exchanges": .array(exchanges)]))
    }
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    files["cases.json"] = try encoder.encode(JSONValue.array(cases))
    files["tree.json"] = try encoder.encode(JSONValue.object(trees))
    files["provenance.json"] = try encoder.encode(
      JSONValue.object([
        "recordedBy": .string(
          "CapabilityReadOracleContractTests.testSwiftReadsTheSharedCapabilityOracle"),
        "nowUTC": .string(Self.nowUTC),
        "storeLabel": .string(Self.storeLabel),
        "checkpointEveryEvents": .integer(Int64(RuntimeCapabilityStore.checkpointEveryEvents)),
      ]))
    try Self.recordOrCompare(
      files, oracle: Self.oracle, variable: "ARKDECK_RUST_CAPABILITY_READ_RECORD")
  }

  // MARK: - Scenarios

  private static func scenarios(in stores: URL) async throws -> [Scenario] {
    var scenarios: [Scenario] = []
    func store(_ name: String) throws -> RuntimeCapabilityStore {
      try RuntimeCapabilityStore(
        directoryURL: stores.appending(path: name, directoryHint: .isDirectory))
    }
    func inspect(_ capabilityID: String) -> Read {
      Read(method: "capability.inspect", params: ["capabilityId": .string(capabilityID)])
    }
    let list = Read(method: "capability.list", params: [:])
    let unnamed = Read(method: "capability.inspect", params: [:])

    // A store nothing was ever installed in: the reads create its lock.
    _ = try store("empty")
    scenarios.append(
      Scenario(name: "empty", reads: [list, inspect("CAP-RT-NOT-INSTALLED"), unnamed]))

    // One install: a checkpoint and no ledger yet.
    let installed = try store("installedOnly")
    try await installed.install(try inputGrant(id: "CAP-RT-INSTALLED", maximumUses: 2))
    scenarios.append(Scenario(name: "installedOnly", reads: [list, inspect("CAP-RT-INSTALLED")]))

    // An install after a use rewrites the checkpoint and empties the ledger.
    let emptied = try store("emptyLedger")
    try await emptied.install(try inputGrant(id: "CAP-RT-EMPTIED", maximumUses: 2))
    try await use(emptied, "CAP-RT-EMPTIED", "d1", tapQuery(plan: 11), [(.confirmed, "succeeded")])
    try await emptied.install(try inputGrant(id: "CAP-RT-EMPTIED-NEXT", maximumUses: 1))
    scenarios.append(Scenario(name: "emptyLedger", reads: [list, inspect("CAP-RT-EMPTIED")]))

    // Every lineage state, a revocation and the periodic checkpoint.
    let ledger = try store("ledger")
    try await ledger.install(try deviceStandingGrant())
    try await ledger.install(try flashPolicyCapability())
    try await ledger.install(try workspaceRouteGrant())
    try await ledger.install(try revocableGrant())
    try await ledger.install(
      try inputGrant(
        id: "CAP-RT-UNRESOLVED", target: .stablePhysicalIdentity(sha256: deviceA), maximumUses: 3))
    try await ledger.install(try inputGrant(id: "CAP-RT-LONG-LEDGER", maximumUses: 70))
    try await ledger.revoke(
      capabilityID: "CAP-RT-REVOKED", atUTC: "2026-09-13T12:00:00Z",
      reason: "withdrawn by the capability oracle")
    try await use(
      ledger, "CAP-RT-DEVICE-STANDING", "a1", debugQuery(plan: 1), [(.confirmed, "succeeded")])
    try await use(
      ledger, "CAP-RT-DEVICE-STANDING", "a2", debugQuery(plan: 2),
      [(.outcomeUnknown, "waitingForRecovery"), (.confirmed, "failed")])
    try await use(ledger, "CAP-RT-DEVICE-STANDING", "a3", debugQuery(plan: 3), [])
    try await use(
      ledger, "CAP-RT-POLICY-FLASH-G1", "b1", flashQuery(),
      [(.outcomeUnknown, "waitingForRecovery"), (.safeToReflash, "failed")])
    try await use(
      ledger, "CAP-RT-WORKSPACE-ROUTE", "c1",
      workspaceQuery(
        "workspace.apply-patch", revision: 1, plan: 31,
        inputs: [
          "projectRef": .string("demo-app"),
          "patchArtifactRef": .string(
            "lease-v1:import:imp-00000000-0000-4000-8000-000000000001:ART-00000000000000000000000000000001"
          ),
          "allowedFileGlobs": .array([.string("entry/src/**")]),
        ]),
      [(.confirmed, "succeeded")])
    try await use(
      ledger, "CAP-RT-WORKSPACE-ROUTE", "c2",
      workspaceQuery(
        "workspace.build-openharmony", revision: 2, plan: 32,
        inputs: ["projectRef": .string("demo-app")]),
      [(.confirmed, "succeeded")])
    try await use(
      ledger, "CAP-RT-UNRESOLVED", "e1", tapQuery(plan: 41),
      [(.outcomeUnknown, "waitingForRecovery")])
    // 15 events so far and 120 more: the 129th rewrites the checkpoint and
    // the last six stay appended.
    for index in 1...60 {
      try await use(
        ledger, "CAP-RT-LONG-LEDGER", "f\(index)", tapQuery(plan: 100 + index),
        [(.confirmed, "succeeded")])
    }
    XCTAssertEqual(try ledgerLines(stores.appending(path: "ledger")).count, 6)
    scenarios.append(
      Scenario(
        name: "ledger",
        reads: [
          list, inspect("CAP-RT-DEVICE-STANDING"), inspect("CAP-RT-POLICY-FLASH-G1"),
          inspect("CAP-RT-WORKSPACE-ROUTE"), inspect("CAP-RT-REVOKED"),
          inspect("CAP-RT-UNRESOLVED"), inspect("CAP-RT-LONG-LEDGER"),
          inspect("CAP-RT-NOT-INSTALLED"), unnamed,
        ]))

    // The base the defects are cut from: a lineage in the checkpoint (the
    // second install rewrote it) and three events in the ledger.
    let base = try store("base")
    try await base.install(try deviceGrant(id: "CAP-RT-BASE", maximumUses: 5))
    try await use(base, "CAP-RT-BASE", "g1", debugQuery(plan: 51), [(.confirmed, "succeeded")])
    try await use(
      base, "CAP-RT-BASE", "g2", debugQuery(plan: 52),
      [(.outcomeUnknown, "waitingForRecovery"), (.confirmed, "failed")])
    try await use(base, "CAP-RT-BASE", "g3", debugQuery(plan: 53), [])
    try await base.install(try inputGrant(id: "CAP-RT-BASE-LEDGER", maximumUses: 3))
    try await use(base, "CAP-RT-BASE-LEDGER", "h1", tapQuery(plan: 61), [(.confirmed, "succeeded")])
    try await use(base, "CAP-RT-BASE-LEDGER", "h2", tapQuery(plan: 62), [])
    let baseDirectory = stores.appending(path: "base", directoryHint: .isDirectory)
    XCTAssertEqual(try ledgerLines(baseDirectory).count, 3)
    scenarios.append(
      Scenario(name: "base", reads: [list, inspect("CAP-RT-BASE"), inspect("CAP-RT-BASE-LEDGER")]))

    let defectReads = [list, inspect("CAP-RT-BASE")]
    func variant(_ name: String, _ edit: (URL) throws -> Void) throws {
      let directory = stores.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.copyItem(at: baseDirectory, to: directory)
      try edit(directory)
      scenarios.append(Scenario(name: name, reads: defectReads))
    }
    let zeros = String(repeating: "0", count: 64)

    try variant("tornFinalAppend") { directory in
      try appendLedger(directory, try ledgerLines(directory)[0].prefix(40))
    }
    try variant("checkpointMissing") { directory in
      try FileManager.default.removeItem(at: directory.appending(path: checkpointName))
    }
    try variant("checkpointLinked") { directory in
      try link(directory, checkpointName, to: "linked-checkpoint.json")
    }
    try variant("ledgerLinked") { directory in
      try link(directory, ledgerName, to: "linked-ledger.jsonl")
    }
    try variant("duplicateMember") { directory in
      let url = directory.appending(path: checkpointName)
      var text = try String(contentsOf: url, encoding: .utf8)
      let anchor = "\"remainingUses\" : 2"
      XCTAssertEqual(text.components(separatedBy: anchor).count, 2)
      let range = try XCTUnwrap(text.range(of: anchor))
      text.replaceSubrange(range, with: anchor + ",\n      " + anchor)
      try write(Data(text.utf8), to: url)
    }
    try variant("truncatedCheckpoint") { directory in
      let url = directory.appending(path: checkpointName)
      let data = try Data(contentsOf: url)
      try write(data.prefix(data.count / 2), to: url)
    }
    try variant("trailingData") { directory in
      let url = directory.appending(path: checkpointName)
      try write(try Data(contentsOf: url) + Data("\n]".utf8), to: url)
    }
    try variant("unknownDocumentMember") { directory in
      try editCheckpoint(directory) { $0["retired"] = .bool(true) }
    }
    try variant("unknownCapabilityMember") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) { try object("capability", of: &$0) { $0["retired"] = .bool(true) } }
      }
    }
    try variant("capabilityInvariant") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try object("capability", of: &$0) { $0["issuedAtUTC"] = .string("2026-09-01") }
        }
      }
    }
    try variant("unknownEffect") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try object("capability", of: &$0) { $0["effectCeiling"] = .string("sideways") }
        }
      }
    }
    try variant("missingMember") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) { $0["remainingUses"] = nil }
      }
    }
    try variant("wrongMemberType") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) { $0["remainingUses"] = .string("two") }
      }
    }
    try variant("nullMember") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) { $0["consumptions"] = .null }
      }
    }
    try variant("wrongNestedType") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try object("capability", of: &$0) { $0["targetScope"] = .string("anyTarget") }
        }
      }
    }
    try variant("unknownTargetKind") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try object("capability", of: &$0) {
            try object("targetScope", of: &$0) { $0["kind"] = .string("planet") }
          }
        }
      }
    }
    try variant("unsupportedEffectCeiling") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try object("capability", of: &$0) { $0["effectCeiling"] = .string("readOnly") }
        }
      }
    }
    try variant("nullCapabilityOptional") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try object("capability", of: &$0) { $0["exactPlanDigest"] = .null }
        }
      }
    }
    try variant("nullOptional") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try element(0, of: "consumptions", in: &$0) { $0["previousLineageSHA256"] = .null }
        }
      }
    }
    // Numbers the store never writes but a decoder still meets.
    for (name, spelling) in [("integralFloatMember", "2.0"), ("fractionalMember", "2.5")] {
      try variant(name) { directory in
        let url = directory.appending(path: checkpointName)
        var text = try String(contentsOf: url, encoding: .utf8)
        let anchor = "\"remainingUses\" : 2"
        XCTAssertEqual(text.components(separatedBy: anchor).count, 2)
        let range = try XCTUnwrap(text.range(of: anchor))
        text.replaceSubrange(range, with: "\"remainingUses\" : \(spelling)")
        try write(Data(text.utf8), to: url)
      }
    }
    try variant("unsupportedSchemaVersion") { directory in
      try editCheckpoint(directory) { $0["schemaVersion"] = .string("2.0.0") }
    }
    try variant("duplicateCapability") { directory in
      try editCheckpoint(directory) { document in
        guard case .array(let records)? = document["records"] else {
          throw CocoaError(.coderInvalidValue)
        }
        document["records"] = .array(records + [records[0]])
      }
    }
    try variant("useAccounting") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) { $0["remainingUses"] = .integer(3) }
      }
    }
    try variant("lineageOrdering") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try element(1, of: "consumptions", in: &$0) { $0["ordinal"] = .integer(3) }
        }
      }
    }
    try variant("receiptDigest") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try element(0, of: "consumptions", in: &$0) { $0["receiptSHA256"] = .string(zeros) }
        }
      }
    }
    try variant("outcomeTransition") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try element(0, of: "consumptions", in: &$0) { use in
            guard case .array(let outcomes)? = use["outcomes"], case .object(var again) = outcomes[0],
              let settled = again["recordSHA256"]
            else { throw CocoaError(.coderInvalidValue) }
            again["previousRecordSHA256"] = settled
            use["outcomes"] = .array(outcomes + [.object(again)])
          }
        }
      }
    }
    try variant("outcomeDigest") { directory in
      try editCheckpoint(directory) { document in
        try record(0, of: &document) {
          try element(0, of: "consumptions", in: &$0) {
            try element(0, of: "outcomes", in: &$0) { $0["recordSHA256"] = .string(zeros) }
          }
        }
      }
    }
    try variant("ledgerGarbage") { directory in
      try appendLedger(directory, Data("not json\n".utf8))
    }
    try variant("ledgerExtraMember") { directory in
      try appendLedger(directory, try ledgerEvent(directory, line: 2) { $0["retired"] = .bool(true) })
    }
    try variant("ledgerUnknownKind") { directory in
      try appendLedger(
        directory,
        try line([
          "capabilityID": .string("CAP-RT-BASE-LEDGER"), "kind": .string("spent"),
        ]))
    }
    try variant("ledgerUnknownCapability") { directory in
      try appendLedger(
        directory,
        try ledgerEvent(directory, line: 0) {
          $0["capabilityID"] = .string("CAP-RT-NOT-INSTALLED")
        })
    }
    try variant("ledgerConsumeWithoutUse") { directory in
      try appendLedger(
        directory,
        try line([
          "capabilityID": .string("CAP-RT-BASE-LEDGER"), "kind": .string("consumed"),
        ]))
    }
    try variant("ledgerOutcomeWithoutRecord") { directory in
      try appendLedger(
        directory,
        try line([
          "capabilityID": .string("CAP-RT-BASE-LEDGER"), "kind": .string("outcome"),
          "reservationID": .string("res-h2"),
        ]))
    }
    try variant("ledgerOrphanOutcome") { directory in
      try appendLedger(
        directory,
        try ledgerEvent(directory, line: 1) { $0["reservationID"] = .string("res-not-taken") })
    }
    try variant("ledgerDuplicateReservation") { directory in
      try appendLedger(directory, try ledgerEvent(directory, line: 0) { _ in })
    }
    try variant("ledgerBreaksLineage") { directory in
      try appendLedger(
        directory,
        try ledgerEvent(directory, line: 0) { event in
          try object("consumption", of: &event) {
            $0["reservationID"] = .string("res-h3")
            $0["remainingUsesAfter"] = .integer(0)
          }
        })
    }
    return scenarios
  }

  // MARK: - Capabilities and uses

  /// A device standing grant for `debug.hap@1` with every input constraint kind.
  private static func deviceStandingGrant() throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-DEVICE-STANDING",
      targetScope: .stablePhysicalIdentity(sha256: deviceA),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      inputConstraints: [
        "bundleName": .exactString("com.example.oracle"),
        "abilityName": .oneOfStrings(["EntryAbility", "SecondAbility"]),
        "diagnosticsDurationSeconds": .integerRange(minimum: 1, maximum: 600),
      ],
      issuedAtUTC: "2026-09-01T00:00:00Z", expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 8,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#capability-read-oracle device"),
      exactBindingRevision: 7)
  }

  private static let flashInputs: [String: JSONValue] = [
    "deviceProfile": .string("dayu200"),
    "imageBundleLease": .string("lease-v1:job:job-oracle-images:ART-0123456789abcdef0123456789abcdef"),
    "partitionPlan": .object([
      "mode": .string("full"), "partitions": .array([.string("boot"), .string("system")]),
    ]),
    "postFlashVerification": .bool(true),
  ]
  private static let flashFacts = [
    "artifactId": "ART-0123456789abcdef0123456789abcdef",
    "artifactSha256": String(repeating: "9", count: 64),
    "artifactByteCount": "1048576",
  ]

  /// A destructive capability the Runtime issues from its Catalog policy.
  private static func flashPolicyCapability() throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-POLICY-FLASH-G1",
      targetScope: .stablePhysicalIdentity(sha256: deviceC),
      operationScope: [.init(operationID: "flash.dayu200")],
      effectCeiling: .destructive,
      exactInputs: flashInputs,
      exactArtifactFacts: flashFacts,
      issuedAtUTC: "2026-09-13T22:00:00Z", expiresAtUTC: "2026-09-14T02:00:00Z",
      maximumUses: 1,
      issuer: .init(kind: .runtimeDefaultPolicy, reference: "catalog:flash.dayu200"),
      exactPlanDigest: plan(20), exactBindingRevision: 3)
  }

  /// A maintainer's standing workspace grant: any revision of one tree.
  private static func workspaceRouteGrant() throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-WORKSPACE-ROUTE",
      targetScope: .workspaceIdentity(
        sha256: workspace, expectedWorkspaceRevision: "", allowedFileScopesDigest: fileScopes),
      operationScope: [
        .init(operationID: "workspace.apply-patch", version: 1),
        .init(operationID: "workspace.build-openharmony", version: 1),
      ],
      effectCeiling: .deviceMutation,
      inputConstraints: ["projectRef": .exactString("demo-app")],
      issuedAtUTC: "2026-09-01T00:00:00Z", expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 4,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#capability-read-oracle workspace"))
  }

  /// A grant revoked before any use; one operation without a version.
  private static func revocableGrant() throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-REVOKED",
      targetScope: .anyTarget,
      operationScope: [
        .init(operationID: "input.tap"), .init(operationID: "input.swipe", version: 1),
      ],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-09-01T00:00:00Z", expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 2,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#capability-read-oracle revoked"))
  }

  private static func inputGrant(
    id: String, target: RuntimeCapabilityTargetScope = .anyTarget, maximumUses: Int
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: id, targetScope: target,
      operationScope: [.init(operationID: "input.tap", version: 1)],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-09-01T00:00:00Z", expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: maximumUses,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#capability-read-oracle input"))
  }

  private static func deviceGrant(id: String, maximumUses: Int) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: id, targetScope: .stablePhysicalIdentity(sha256: deviceA),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-09-01T00:00:00Z", expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: maximumUses,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#capability-read-oracle base"))
  }

  /// A materialized plan digest per use, so every use binds its own plan.
  private static func plan(_ index: Int) -> String {
    SHA256Hex.string(of: Data("capability-read-oracle-plan-\(index)".utf8))
  }

  private static func revision(_ index: Int) -> String {
    SHA256Hex.string(of: Data("capability-read-oracle-revision-\(index)".utf8))
  }

  private static func debugQuery(plan index: Int) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: "debug.hap", operationVersion: 1, effect: .deviceMutation,
      targetStableIdentitySHA256: deviceA, targetBindingRevision: 7, planDigest: plan(index),
      inputs: [
        "abilityName": .string("EntryAbility"), "bundleName": .string("com.example.oracle"),
        "diagnosticsDurationSeconds": .integer(30),
      ])
  }

  private static func tapQuery(plan index: Int) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: "input.tap", operationVersion: 1, effect: .deviceMutation,
      targetStableIdentitySHA256: deviceA, targetBindingRevision: 7, planDigest: plan(index),
      inputs: ["x": .integer(120), "y": .integer(480)])
  }

  private static func flashQuery() -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: "flash.dayu200", operationVersion: nil, effect: .destructive,
      targetStableIdentitySHA256: deviceC, targetBindingRevision: 3, planDigest: plan(20),
      inputs: flashInputs, artifactFacts: flashFacts)
  }

  private static func workspaceQuery(
    _ operation: String, revision index: Int, plan planIndex: Int, inputs: [String: JSONValue]
  ) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: operation, operationVersion: 1, effect: .deviceMutation,
      targetStableIdentitySHA256: nil, targetBindingRevision: nil, planDigest: plan(planIndex),
      inputs: inputs, workspaceIdentitySHA256: workspace, workspaceRevision: revision(index),
      workspaceFileScopesDigest: fileScopes)
  }

  /// One use of a capability by Job `job-<tag>`, then its outcomes in order.
  private static func use(
    _ store: RuntimeCapabilityStore, _ capabilityID: String, _ tag: String,
    _ query: RuntimeCapabilityAuthorizationQuery,
    _ outcomes: [(RuntimeCapabilityUseOutcome, String)]
  ) async throws {
    _ = try await store.consume(
      capabilityID: capabilityID, reservationID: "res-\(tag)", jobID: "job-\(tag)",
      query: query, nowUTC: nowUTC)
    for (index, (outcome, terminalState)) in outcomes.enumerated() {
      try await store.recordOutcome(
        capabilityID: capabilityID, reservationID: "res-\(tag)", jobID: "job-\(tag)",
        outcome: outcome, terminalState: terminalState,
        atUTC: "2026-09-14T00:0\(index + 1):00Z")
    }
  }

  // MARK: - Store edits

  /// Writes a store file as the store does: private to its owner.
  private static func write(_ data: Data, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }

  private static func link(_ directory: URL, _ name: String, to target: String) throws {
    try FileManager.default.moveItem(
      at: directory.appending(path: name), to: directory.appending(path: target))
    try FileManager.default.createSymbolicLink(
      atPath: directory.appending(path: name).path, withDestinationPath: target)
  }

  /// Re-encodes the checkpoint as the store writes it, after `edit`.
  private static func editCheckpoint(
    _ directory: URL, _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws {
    let url = directory.appending(path: checkpointName)
    var document = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    try edit(&document)
    try write(try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object(document)), to: url)
  }

  private static func record(
    _ index: Int, of document: inout [String: JSONValue],
    _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws {
    try element(index, of: "records", in: &document, edit)
  }

  private static func element(
    _ index: Int, of key: String, in object: inout [String: JSONValue],
    _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws {
    guard case .array(var elements)? = object[key], elements.indices.contains(index),
      case .object(var element) = elements[index]
    else { throw CocoaError(.coderInvalidValue) }
    try edit(&element)
    elements[index] = .object(element)
    object[key] = .array(elements)
  }

  private static func object(
    _ key: String, of parent: inout [String: JSONValue],
    _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws {
    guard case .object(var child)? = parent[key] else { throw CocoaError(.coderInvalidValue) }
    try edit(&child)
    parent[key] = .object(child)
  }

  private static func ledgerLines(_ directory: URL) throws -> [Data] {
    try Data(contentsOf: directory.appending(path: ledgerName)).split(separator: 0x0A).map {
      Data($0)
    }
  }

  private static func appendLedger(_ directory: URL, _ data: Data) throws {
    let handle = try FileHandle(forWritingTo: directory.appending(path: ledgerName))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  /// One ledger event as the store appends it.
  private static func line(_ event: [String: JSONValue]) throws -> Data {
    var data = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(event))
    data.append(0x0A)
    return data
  }

  /// The ledger's event at `line`, edited and appended as the store appends.
  private static func ledgerEvent(
    _ directory: URL, line index: Int, _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws -> Data {
    var event = try JSONDecoder().decode(
      [String: JSONValue].self, from: try ledgerLines(directory)[index])
    try edit(&event)
    return try line(event)
  }

  // MARK: - Reads

  /// The daemon's control plane over a store opened afresh on `directory`.
  private static func handler(
    over directory: URL, engineState: URL
  ) throws -> RuntimeControlPlaneHandler {
    let store = try RuntimeCapabilityStore(directoryURL: directory)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: engineState),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: OracleRefusingDispatcher(),
      capabilityStore: store,
      nowUTC: { CapabilityReadOracleContractTests.nowUTC })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: store, providerIDs: [],
      nowUTC: { CapabilityReadOracleContractTests.nowUTC })
  }

  /// One control frame through the handler, answered as the oracle records it.
  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("capability-read-oracle"), "method": .string(method),
        "params": .object(params),
      ]))
    let response = await handler.handleFrame(frame)
    var fields: [String: JSONValue] = ["ok": .bool(response.ok)]
    if let result = response.result { fields["result"] = result }
    if let error = response.error {
      var body: [String: JSONValue] = [
        "code": .string(error.code), "message": .string(error.message),
      ]
      if let details = error.details { body["details"] = .object(details) }
      fields["error"] = .object(body)
    }
    return .object(fields)
  }

  /// The answer with the store's directory spelled `<store>`.
  private static func labelled(_ response: JSONValue, directory: URL) -> JSONValue {
    guard case .object(var fields) = response, case .object(var error)? = fields["error"],
      case .string(let message)? = error["message"]
    else { return response }
    error["message"] = .string(message.replacingOccurrences(of: directory.path, with: storeLabel))
    fields["error"] = .object(error)
    return .object(fields)
  }

  /// Every entry of a store directory with its kind and mode, and the bytes
  /// of every regular file.
  private static func entries(
    of directory: URL
  ) throws -> (tree: JSONValue, contents: [String: Data]) {
    let manager = FileManager.default
    var tree: [JSONValue] = []
    var contents: [String: Data] = [:]
    for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() {
      let url = directory.appending(path: name)
      let attributes = try manager.attributesOfItem(atPath: url.path)
      var entry: [String: JSONValue] = ["path": .string(name)]
      switch attributes[.type] as? FileAttributeType {
      case .typeSymbolicLink?:
        entry["kind"] = .string("symlink")
        entry["target"] = .string(try manager.destinationOfSymbolicLink(atPath: url.path))
      case .typeRegular?:
        let data = try Data(contentsOf: url)
        entry["kind"] = .string("file")
        entry["mode"] = .string(
          String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, radix: 8))
        entry["size"] = .integer(Int64(data.count))
        contents[name] = data
      default:
        entry["kind"] = .string("other")
      }
      tree.append(.object(entry))
    }
    return (.array(tree), contents)
  }

  /// Writes a new oracle when `variable` names a new directory under
  /// `/private/tmp`; otherwise the checked-in oracle must match byte for byte.
  private static func recordOrCompare(
    _ files: [String: Data], oracle: URL, variable: String
  ) throws {
    if let output = ProcessInfo.processInfo.environment[variable] {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    XCTAssertEqual(Set(recorded), Set(files.keys))
    let expected = try Dictionary(uniqueKeysWithValues: recorded.map { path in
      (path, try Data(contentsOf: oracle.appending(path: path)))
    })
    let comparableExpected = try OracleSDKDiagnosticCompatibility.comparableFiles(expected, family: .capabilityRead)
    let comparableActual = try OracleSDKDiagnosticCompatibility.comparableFiles(files, family: .capabilityRead)
    for (path, data) in comparableActual {
      XCTAssertEqual(comparableExpected[path], data, path)
    }
  }
}

/// Dispatches nothing: a capability read never reaches a provider.
private struct OracleRefusingDispatcher: RuntimeProcessDispatching {
  func unavailableReason(providerID: String) -> String? {
    "the capability oracle dispatches nothing"
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed("the capability oracle dispatches nothing")
  }
}
