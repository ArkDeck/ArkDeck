// Shared Swift oracle for the Rust superseding-recovery-epoch store
// (TASK-XPA-014, recovery port slice 3).
//
// `RecoveryCoordination.swift`'s `RuntimeSupersedingRecoveryStore` carries
// ADR-0009 decision 4 in the CHG-2026-074 decision package
// (`evidence/adr-0009-decision-package-20260914.md` §1c and §2): an
// append-only, hash-chained relation proving that a later complete overwrite
// established a known target epoch, which covered intents never rewrite. The
// maintainer ruled on 2026-09-19 that Rust ports it unchanged.
//
// This oracle drives one store through its whole vocabulary and records, after
// every step, what it answered and the files it left: the first and a second
// chained append, the idempotent repeat, the two conflicts (a drifted proof,
// and an epoch identity already taken), every draft refusal, and the load
// refusals of a document or lock that was tampered with, reordered,
// truncated, re-versioned, widened, linked, oversized or opened to others. The
// Rust store replays every step and must answer the same and leave the same
// bytes.
//
// Everything here is host-local: no device, no daemon. Record a new oracle
// with `ARKDECK_RUST_RECOVERY_EPOCH_RECORD=/private/tmp/<new directory>`;
// otherwise the checked-in oracle must match byte for byte.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class RecoveryEpochOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/recovery-epoch", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_RECOVERY_EPOCH_RECORD"
  private static let documentName = "superseding-recovery-epochs.json"
  private static let lockName = ".superseding-recovery-epochs.lock"
  private static let maximumDocumentBytes = 1_048_576

  private var scratch: URL!
  private var steps: [JSONValue] = []
  private var files: [String: Data] = [:]

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-recovery-epoch-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  private static func hex(_ digit: Character) -> String { String(repeating: digit, count: 64) }

  private static func effectDigest(_ effects: [String]) -> String {
    SHA256Hex.string(of: Data(Array(Set(effects)).sorted().joined(separator: "\n").utf8))
  }

  private static func intent(_ job: String, _ effects: [String]) -> SupersededRecoveryIntent {
    SupersededRecoveryIntent(
      jobID: job, intentEventID: "\(job)-intent-7", operationReference: "flash.dayu200",
      profileReference: "dayu200", observedAtUTC: "2026-08-08T00:00:00Z",
      possibleEffects: effects)
  }

  /// A draft whose every member can be replaced; the defaults are a complete
  /// historical recognition covering two unknown Jobs.
  private static func draft(
    source: SupersedingRecoverySource = .historicalRecognition,
    identity: String = hex("a"),
    bindingRevision: Int = 2,
    intents: [SupersededRecoveryIntent]? = nil,
    uncertain: String? = nil,
    recoveryJob: String = "job-recovery",
    recoveryIntent: String = "job-recovery-intent-9",
    provider: String = hex("4"),
    confirmed: [String] = ["flash-partitions", "verify-flash-readback"],
    established: String = "2026-08-08T00:20:00Z"
  ) -> SupersedingRecoveryEpochDraft {
    let covered =
      intents ?? [
        intent("job-old-a", ["partition:system", "partition:userdata"]),
        intent("job-old-b", ["partition:userdata", "partition:vendor"]),
      ]
    return SupersedingRecoveryEpochDraft(
      source: source, stableTargetIdentitySHA256: identity, bindingRevision: bindingRevision,
      coveredIntents: covered,
      uncertainEffectSetSHA256: uncertain ?? effectDigest(covered.flatMap(\.possibleEffects)),
      coverageContractVersion: "1.0.0", coveredEffectSetSHA256: hex("1"),
      recoveryJobID: recoveryJob, recoveryIntentEventID: recoveryIntent,
      operationReference: "flash.dayu200", profileReference: "dayu200",
      materializedPlanDigestSHA256: hex("2"), artifactSHA256: hex("3"),
      providerExecutableSHA256: provider, confirmedStepIDs: confirmed,
      resultingTargetEpochSHA256: hex("7"), establishedAtUTC: established)
  }

  private static func json(_ draft: SupersedingRecoveryEpochDraft) -> JSONValue {
    .object([
      "source": .string(draft.source.rawValue),
      "stableTargetIdentitySHA256": .string(draft.stableTargetIdentitySHA256),
      "bindingRevision": .integer(Int64(draft.bindingRevision)),
      "coveredIntents": .array(
        draft.coveredIntents.map { intent in
          .object([
            "jobID": .string(intent.jobID), "intentEventID": .string(intent.intentEventID),
            "operationReference": .string(intent.operationReference),
            "profileReference": .string(intent.profileReference),
            "observedAtUTC": .string(intent.observedAtUTC),
            "possibleEffects": .array(intent.possibleEffects.map(JSONValue.string)),
          ])
        }),
      "uncertainEffectSetSHA256": .string(draft.uncertainEffectSetSHA256),
      "coverageContractVersion": .string(draft.coverageContractVersion),
      "coveredEffectSetSHA256": .string(draft.coveredEffectSetSHA256),
      "recoveryJobID": .string(draft.recoveryJobID),
      "recoveryIntentEventID": .string(draft.recoveryIntentEventID),
      "operationReference": .string(draft.operationReference),
      "profileReference": .string(draft.profileReference),
      "materializedPlanDigestSHA256": .string(draft.materializedPlanDigestSHA256),
      "artifactSHA256": .string(draft.artifactSHA256),
      "providerExecutableSHA256": .string(draft.providerExecutableSHA256),
      "confirmedStepIDs": .array(draft.confirmedStepIDs.map(JSONValue.string)),
      "resultingTargetEpochSHA256": .string(draft.resultingTargetEpochSHA256),
      "establishedAtUTC": .string(draft.establishedAtUTC),
    ])
  }

  private static func json(_ epoch: SupersedingRecoveryEpoch) throws -> JSONValue {
    try JSONDecoder().decode(
      JSONValue.self, from: CanonicalJSONEncoders.canonical().encode(epoch))
  }

  /// What the store answered, by kind; message text is T2 and not recorded,
  /// except the epoch identity a conflict names.
  private static func refusal(_ error: any Error) -> JSONValue {
    guard let error = error as? SupersedingRecoveryStoreError else {
      return .object(["refused": .string("unexpected: \(error)")])
    }
    switch error {
    case .corrupt: return .object(["refused": .string("corrupt")])
    case .invalidEpoch: return .object(["refused": .string("invalidEpoch")])
    case .conflictingEpoch(let epochID):
      return .object(["refused": .string("conflictingEpoch"), "epochId": .string(epochID)])
    }
  }

  private func appended(
    _ store: RuntimeSupersedingRecoveryStore, _ draft: SupersedingRecoveryEpochDraft
  ) async throws -> JSONValue {
    do {
      return .object(["epoch": try Self.json(try await store.append(draft))])
    } catch { return Self.refusal(error) }
  }

  private func listed(_ store: RuntimeSupersedingRecoveryStore) async throws -> JSONValue {
    do {
      return .object(["epochs": .array(try await store.list().map(Self.json))])
    } catch { return Self.refusal(error) }
  }

  /// Records a step: the root it ran on (`main`, or a root of its own), how
  /// that root was seeded when the step created it (`document` names the step
  /// whose recorded document it holds), its input, the store's answer, and
  /// the root's files with their modes and link counts.
  private func step(
    _ name: String, root: URL, store: String = "main", seed: JSONValue = .null,
    operation: String, input: JSONValue, outcome: JSONValue
  ) throws {
    let stem = String(format: "%02d-%@", steps.count + 1, name)
    var entries: [String: JSONValue] = [:]
    for file in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
      var metadata = stat()
      XCTAssertEqual(lstat(root.appending(path: file).path, &metadata), 0, file)
      let data = try Data(contentsOf: root.appending(path: file))
      var entry: [String: JSONValue] = [
        "mode": .string(String(metadata.st_mode & 0o7777, radix: 8)),
        "links": .integer(Int64(metadata.st_nlink)),
        "bytes": .integer(Int64(data.count)),
        "sha256": .string(SHA256Hex.string(of: data)),
      ]
      if data.count <= 65_536 {
        let path = "steps/\(stem)/\(file)"
        files[path] = data
        entry["file"] = .string(path)
      }
      entries[file] = .object(entry)
    }
    steps.append(
      .object([
        "name": .string(name), "store": .string(store), "seed": seed,
        "operation": .string(operation), "input": input, "outcome": outcome,
        "root": .object(entries),
      ]))
  }

  /// A fresh root holding `document` as the store writes it (0600), for a
  /// load refusal recorded on its own.
  private func seeded(_ name: String, _ document: Data) throws -> URL {
    let root = scratch.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try DurableFileWriter.createOrReplaceAtomically(
      destination: root.appending(path: Self.documentName), data: document)
    return root
  }

  private static func edited(
    _ document: Data, _ body: (inout [String: JSONValue]) throws -> Void
  ) throws -> Data {
    guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: document)
    else { throw CocoaError(.coderInvalidValue) }
    try body(&object)
    return try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object(object))
  }

  private static func epochs(_ object: [String: JSONValue]) -> [JSONValue] {
    guard case .array(let epochs)? = object["epochs"] else { return [] }
    return epochs
  }

  func testSwiftStoreAppendsChainsAndRefusesAsItsOwnDocumentAllows() async throws {
    let root = scratch.appending(path: "store", directoryHint: .isDirectory)
    let store = try RuntimeSupersedingRecoveryStore(stateDirectory: root)
    let none = JSONValue.null

    // An empty root lists nothing; the lock is created, the document is not.
    try step("list-empty", root: root, operation: "list", input: none, outcome: try await listed(store))

    // The first epoch has no predecessor.
    let first = Self.draft()
    try step("append-first", root: root, operation: "append", input: Self.json(first),
      outcome: try await appended(store, first))

    // The same proof again is the same epoch; nothing is rewritten.
    try step("append-first-again", root: root, operation: "append", input: Self.json(first),
      outcome: try await appended(store, first))

    // The same recovery key with a drifted proof is refused, naming the epoch.
    let drifted = Self.draft(provider: Self.hex("5"))
    try step("append-drifted-proof", root: root, operation: "append", input: Self.json(drifted),
      outcome: try await appended(store, drifted))

    // Covering a different intent set under the same recovery intent is a new
    // relation key, but its content-derived epoch identity is taken.
    let taken = Self.draft(intents: [
      Self.intent("job-old-c", ["partition:system", "partition:userdata", "partition:vendor"])
    ])
    try step("append-identity-taken", root: root, operation: "append", input: Self.json(taken),
      outcome: try await appended(store, taken))

    // A distinct recovery execution chains to the first epoch.
    let second = Self.draft(
      source: .distinctRecoveryExecution,
      intents: [Self.intent("job-old-d", ["partition:boot"])],
      recoveryJob: "job-recovery-2", recoveryIntent: "job-recovery-2-intent-4",
      provider: Self.hex("6"), confirmed: ["flash-partitions"],
      established: "2026-08-08T05:00:00Z")
    try step("append-second", root: root, operation: "append", input: Self.json(second),
      outcome: try await appended(store, second))

    // Drafts the store refuses before it takes its lock.
    let refusals: [(String, SupersedingRecoveryEpochDraft)] = [
      ("invalid-binding-revision", Self.draft(bindingRevision: 0, recoveryJob: "job-invalid")),
      ("invalid-identity-uppercase", Self.draft(identity: Self.hex("A"), recoveryJob: "job-invalid")),
      ("invalid-no-intents", Self.draft(intents: [], recoveryJob: "job-invalid")),
      ("invalid-duplicate-intent", Self.draft(
        intents: [Self.intent("job-old-e", ["partition:boot"]), Self.intent("job-old-e", ["partition:boot"])],
        recoveryJob: "job-invalid")),
      ("invalid-empty-effects", Self.draft(
        intents: [Self.intent("job-old-f", [])], uncertain: Self.effectDigest([]),
        recoveryJob: "job-invalid")),
      ("invalid-duplicate-effect", Self.draft(
        intents: [Self.intent("job-old-g", ["partition:boot", "partition:boot"])],
        recoveryJob: "job-invalid")),
      ("invalid-uncertain-digest", Self.draft(uncertain: Self.hex("9"), recoveryJob: "job-invalid")),
      ("invalid-no-confirmed-step", Self.draft(recoveryJob: "job-invalid", confirmed: [])),
      ("invalid-duplicate-confirmed-step", Self.draft(
        recoveryJob: "job-invalid", confirmed: ["flash-partitions", "flash-partitions"])),
      ("invalid-empty-intent-job", Self.draft(
        intents: [Self.intent("", ["partition:boot"])], recoveryJob: "job-invalid")),
    ]
    for (name, draft) in refusals {
      try step(name, root: root, operation: "append", input: Self.json(draft),
        outcome: try await appended(store, draft))
    }

    // The chain as it stands.
    try step("list-two", root: root, operation: "list", input: none, outcome: try await listed(store))

    // Load refusals, each on its own root seeded with the chain above.
    let document = try Data(contentsOf: root.appending(path: Self.documentName))
    let loads: [(String, Data)] = [
      ("load-changed-material", try Self.edited(document) { object in
        var epochs = Self.epochs(object)
        guard case .object(var epoch) = epochs[1] else { return }
        epoch["providerExecutableSHA256"] = .string(Self.hex("8"))
        epochs[1] = .object(epoch)
        object["epochs"] = .array(epochs)
      }),
      ("load-reordered", try Self.edited(document) { object in
        object["epochs"] = .array(Self.epochs(object).reversed())
      }),
      ("load-first-removed", try Self.edited(document) { object in
        object["epochs"] = .array(Array(Self.epochs(object).dropFirst()))
      }),
      ("load-schema-version", try Self.edited(document) { $0["schemaVersion"] = .string("1.0.1") }),
      ("load-invalid-epoch", try Self.edited(document) { object in
        var epochs = Self.epochs(object)
        guard case .object(var epoch) = epochs[0] else { return }
        epoch["bindingRevision"] = .integer(0)
        epochs[0] = .object(epoch)
        object["epochs"] = .array(epochs)
      }),
      ("load-epoch-member-missing", try Self.edited(document) { object in
        var epochs = Self.epochs(object)
        guard case .object(var epoch) = epochs[0] else { return }
        epoch.removeValue(forKey: "artifactSHA256")
        epochs[0] = .object(epoch)
        object["epochs"] = .array(epochs)
      }),
      ("load-epoch-member-unknown", try Self.edited(document) { object in
        var epochs = Self.epochs(object)
        guard case .object(var epoch) = epochs[0] else { return }
        epoch["note"] = .string("not part of the material")
        epochs[0] = .object(epoch)
        object["epochs"] = .array(epochs)
      }),
      ("load-document-member-unknown", try Self.edited(document) {
        $0["note"] = .string("not part of the document")
      }),
      ("load-not-json", Data("{\"schemaVersion\" : \"1.0.0\", \"epochs\" : [".utf8)),
    ]
    for (name, bytes) in loads {
      let seededRoot = try seeded(name, bytes)
      let seededStore = try RuntimeSupersedingRecoveryStore(stateDirectory: seededRoot)
      try step(name, root: seededRoot, store: name, seed: .object(["document": .string(name)]),
        operation: "list", input: .null, outcome: try await listed(seededStore))
    }

    // A document or lock open to others, a linked document, and an oversized
    // one are refused before any byte is decoded.
    let widened = try seeded("load-document-mode-0644", document)
    XCTAssertEqual(chmod(widened.appending(path: Self.documentName).path, 0o644), 0)
    try step("load-document-mode-0644", root: widened, store: "load-document-mode-0644",
      seed: .object(["document": .string("list-two"), "documentMode": .string("644")]),
      operation: "list", input: .null,
      outcome: try await listed(try RuntimeSupersedingRecoveryStore(stateDirectory: widened)))

    let linked = try seeded("load-document-linked", document)
    XCTAssertEqual(
      link(
        linked.appending(path: Self.documentName).path,
        linked.appending(path: "second-name.json").path), 0)
    try step("load-document-linked", root: linked, store: "load-document-linked",
      seed: .object(["document": .string("list-two"), "hardLink": .string("second-name.json")]),
      operation: "list", input: .null,
      outcome: try await listed(try RuntimeSupersedingRecoveryStore(stateDirectory: linked)))

    var oversized = document
    oversized.append(Data(repeating: 0x20, count: Self.maximumDocumentBytes + 1 - document.count))
    let large = try seeded("load-document-oversized", oversized)
    try step("load-document-oversized", root: large, store: "load-document-oversized",
      seed: .object([
        "document": .string("list-two"),
        "appendSpacesTo": .integer(Int64(Self.maximumDocumentBytes + 1)),
      ]),
      operation: "list", input: .null,
      outcome: try await listed(try RuntimeSupersedingRecoveryStore(stateDirectory: large)))

    let openLock = try seeded("lock-mode-0644", document)
    let lockPath = openLock.appending(path: Self.lockName).path
    let descriptor = open(lockPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    close(descriptor)
    XCTAssertEqual(chmod(lockPath, 0o644), 0)
    let openLockStore = try RuntimeSupersedingRecoveryStore(stateDirectory: openLock)
    try step("lock-mode-0644-list", root: openLock, store: "lock-mode-0644",
      seed: .object(["document": .string("list-two"), "lockMode": .string("644")]),
      operation: "list", input: .null,
      outcome: try await listed(openLockStore))
    let third = Self.draft(recoveryJob: "job-recovery-3", recoveryIntent: "job-recovery-3-intent-2")
    try step("lock-mode-0644-append", root: openLock, store: "lock-mode-0644", operation: "append",
      input: Self.json(third), outcome: try await appended(openLockStore, third))

    // The seeded chain continues where it stopped: a third epoch links to the
    // second one's digest.
    let continued = try seeded("continue-chain", document)
    let continuedStore = try RuntimeSupersedingRecoveryStore(stateDirectory: continued)
    try step("continue-chain", root: continued, store: "continue-chain",
      seed: .object(["document": .string("list-two")]), operation: "append",
      input: Self.json(third), outcome: try await appended(continuedStore, third))

    try record()
  }

  private func record() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] = try encoder.encode(JSONValue.array(steps)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    let source = try Data(
      contentsOf: Self.repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckStorage/RecoveryCoordination.swift"))
    let provenance: [String: JSONValue] = [
      "producer": .string(
        "RecoveryEpochOracleContractTests.testSwiftStoreAppendsChainsAndRefusesAsItsOwnDocumentAllows"),
      "store": .object([
        "type": .string("RuntimeSupersedingRecoveryStore"),
        "source": .string("Packages/ArkDeckKit/Sources/ArkDeckStorage/RecoveryCoordination.swift"),
        "sourceSHA256": .string(SHA256Hex.string(of: source)),
        "documentName": .string(Self.documentName),
        "lockName": .string(Self.lockName),
        "maximumDocumentBytes": .integer(Int64(Self.maximumDocumentBytes)),
        "rule": .string("the daemon's state directory, beside the Job store"),
      ]),
      "outcomes": .array(
        ["epochs", "epoch", "corrupt", "invalidEpoch", "conflictingEpoch"].map(JSONValue.string)),
      "files": .object(digests),
    ]
    files["provenance.json"] =
      try encoder.encode(JSONValue.object(provenance)) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
