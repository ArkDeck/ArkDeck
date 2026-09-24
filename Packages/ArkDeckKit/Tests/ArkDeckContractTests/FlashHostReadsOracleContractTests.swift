// Shared Swift oracle for the Rust Flash host reads (CHG-2026-074, TASK-XPA-017, milestone M4).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `flash.reconcile-alias`, `debug.status` and
/// `recovery.flash-invocation.list` through the daemon's control-plane
/// handler, composed with the owners the daemon composes for them: the
/// product post-flash alias reconciler over the Target store and the
/// post-flash HDC binding store of the Application Support root (the state
/// directory's parent), and the Runtime Flash invocation controller over the
/// state directory. What the oracle injects is what a host cannot fix: the
/// USB census the reconciler reads in place of the I/O Registry, its clock,
/// and the attempt driver behind the controller (a plan-only preview with one
/// destructive step and scripted execution outcomes; mechanical contract
/// evidence, never device evidence). No device, HDC or daemon process.
///
/// The reconciler's exchanges run in order over one root, each after the
/// setup it names (a file written from `inputs/`, removed or re-moded, the
/// census set), and each records every file of the Application Support root
/// afterwards, byte for byte (`steps/`), so that a replay leaves the same
/// store: its lock, its archived epoch, its republished alias.
///
/// The controller mints a random invocation identity, so the invocation
/// documents are recorded once, from the controller itself: with the record
/// variable set, the oracle starts nine invocations and drives their
/// evaluations (active, observed, stopped, a destructive epoch that was safe
/// to reflash followed by one whose outcome is unknown, succeeded, blocked,
/// refused before dispatch, the canonical `flash.full-restore@1`, and one
/// that expired), keeps the documents under `inputs/invocations/` and the
/// identities under `inputs/invocations/index.json`. Without it the oracle
/// installs the recorded documents and re-answers every exchange; the answers
/// must match byte for byte. The documents the reads refuse (an unknown key,
/// a duplicate member, an explicit null, another schema, another identity, an
/// epoch count past the budget, a shared mode, an empty file, a link, an
/// unknown entry, an invalid identity, a shared directory) are derived from
/// the recorded ones byte for byte, in both modes.
///
/// A list names the snapshot it paged by a revision the pager mints at
/// random, and its next cursor by that revision: the oracle records them as
/// `<snapshotRevision>` and `<nextCursor-N>` (N the exchange that answered
/// it), and a request naming `<nextCursor-N>` sends that exchange's cursor.
///
/// Every request here is one a caller may send under the published request
/// schemas; a parameter the handler ignores or refuses by name (an unknown
/// key, a revision spelled as a string) would publish that name in the
/// request schema, so those refusals are the Rust replay's own.
///
/// Record a new oracle with
/// `ARKDECK_RUST_FLASH_HOST_READS_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class FlashHostReadsOracleContractTests: XCTestCase {
  /// The census the reconciler reads in place of the host's I/O Registry;
  /// `nil` is a registry that cannot be read.
  private final class Census: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [RockchipProductUSBIdentity]? = []

    func set(_ devices: [RockchipProductUSBIdentity]?) { lock.withLock { self.devices = devices } }

    func read() throws -> [RockchipProductUSBIdentity] {
      guard let devices = lock.withLock({ devices }) else {
        // What `RockchipProductUSBProbe.systemIdentities()` throws.
        throw RockchipFlashExecutionError.admissionRejected("USB registry unavailable")
      }
      return devices
    }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }
    func now() -> String { lock.withLock { value } }
    func set(_ value: String) { lock.withLock { self.value = value } }
  }

  /// Stands in for `RuntimeJobEngineDebugAttemptDriver`: the plan-only
  /// preview of exactly the pinned request, with one destructive step, and
  /// each execution's outcome from a script.
  private actor Driver: RuntimeDebugAttemptDriving {
    private var outcomes: [RuntimeDebugExecutionOutcome] = []
    private var executions = 0

    func script(_ outcomes: [RuntimeDebugExecutionOutcome]) { self.outcomes = outcomes }

    func prepare(_ requestData: Data) async throws -> RuntimePlanOnlyPreview {
      let request = try RuntimeOperationCodec.decodeRequest(requestData)
      return RuntimePlanOnlyPreview(
        executionMode: "planOnly",
        operationReference: request.operation.reference,
        targetID: request.target.targetID,
        bindingRevision: request.target.expectedBindingRevision,
        stableIdentitySHA256: FlashHostReadsOracleContractTests.loaderIdentity,
        providerID: "arkforge",
        catalogDigest: String(repeating: "d", count: 64),
        requestFingerprintSHA256: String(repeating: "e", count: 64),
        materializedPlanDigest: String(repeating: "f", count: 64),
        inputs: request.inputs,
        steps: [
          RuntimePlanOnlyStep(
            stepID: "flash-partitions", kind: "flashPartition",
            effect: WorkflowEffect.destructive.rawValue,
            cancellation: "atSafeBoundary", binding: "exactTarget", isOptional: false)
        ],
        effectiveEffect: WorkflowEffect.destructive.rawValue,
        authorizationPolicy: RuntimeOperationAuthorizationPolicy.runtimeCapability.rawValue,
        providerAdmissionBlocker: nil,
        jobAdmitted: false, dispatchDisposition: "notDispatched")
    }

    func execute(_ requestData: Data) async -> RuntimeDebugDriverResult {
      executions += 1
      let outcome = outcomes.isEmpty ? .failedKnown : outcomes.removeFirst()
      return RuntimeDebugDriverResult(
        jobID: outcome == .refused ? nil : "job-oracle-\(executions)",
        outcome: outcome, detail: "oracle driver outcome \(outcome.rawValue)")
    }
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/flash-host-reads", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_FLASH_HOST_READS_RECORD"
  /// The Application Support root: the post-flash alias lives here, the
  /// state directory below it, as the daemon composes both.
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-flash-host-reads-oracle", directoryHint: .isDirectory)
  private static let lockPath = "/private/tmp/arkdeck-flash-host-reads-oracle.lock"
  private static let state = root.appending(path: "state", directoryHint: .isDirectory)
  private static let invocations = "state/runtime-debug-invocations"
  private static let aliasFile = "rockchip-post-flash-hdc-binding.json"
  private static let nowUTC = "2026-09-25T00:00:00Z"

  private static let targetID = "TGT-HOST"
  fileprivate static let loaderIdentity = String(repeating: "a", count: 64)
  private static let otherLoaderIdentity = String(repeating: "b", count: 64)
  /// The DAYU200's HDC serial after the flash, its serial before, and a
  /// second board's.
  private static let hdcKey = "1501ffff00000000000000000000cafe"
  private static let previousKey = "1501ffff000000000000000000000001"
  private static let otherKey = "1501ffff000000000000000000000003"

  private var files: [String: Data] = [:]
  private var exchanges: [JSONValue] = []
  private var setup: [JSONValue] = []
  /// Each list answer's real next cursor, by the exchange that answered it.
  private var cursors: [Int: String] = [:]

  private static func digest(_ text: String) -> String {
    SHA256Hex.string(of: Data(text.utf8))
  }

  private static func hdcNormal(
    _ serial: String, at topology: String, named name: String = "\"HDC Device\""
  ) -> RockchipProductUSBIdentity {
    RockchipProductUSBIdentity(
      serial: serial, vendorID: 0x2207, productID: 0x5000, topology: topology,
      productName: name, registryEntryID: 0x1_0000_0042)
  }

  private static func loader(_ serial: String, at topology: String) -> RockchipProductUSBIdentity {
    RockchipProductUSBIdentity(
      serial: serial, vendorID: 0x2207, productID: 0x350a, topology: topology)
  }

  private static func json(_ device: RockchipProductUSBIdentity) -> JSONValue {
    .object([
      "serial": .string(device.serial),
      "vendorId": .integer(Int64(device.vendorID)),
      "productId": .integer(Int64(device.productID)),
      "topology": .string(device.topology),
      "productName": device.productName.map(JSONValue.string) ?? .null,
      "registryEntryId": device.registryEntryID.map { .integer(Int64($0)) } ?? .null,
    ])
  }

  private static func targets(revision: Int) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "schemaVersion": .string("1.0.0"),
        "targets": .array([
          .object([
            "targetID": .string(targetID),
            "stablePhysicalIdentitySHA256": .string(loaderIdentity),
            "bindingRevision": .integer(Int64(revision)),
            "connectKey": .string(hdcKey),
            "toolVersion": .string("3.2.0f"),
            "adoptedAtUTC": .string("2026-09-01T00:00:00Z"),
          ])
        ]),
      ]))
  }

  /// The alias as the store writes it: its canonical bytes and a newline.
  private static func alias(
    revision: Int, loader: String = loaderIdentity, topology: String = "42"
  ) throws -> Data {
    let record = RockchipPostFlashHDCBinding(
      targetID: targetID, bindingRevision: revision,
      stableLoaderIdentitySHA256: loader,
      previousHDCIdentitySHA256: digest(previousKey),
      hdcIdentitySHA256: digest(hdcKey), hdcConnectKey: hdcKey,
      usbTopology: topology, productModel: "ohos", buildVersion: "OpenHarmony-7.0.0.36",
      jobID: "job-flash-host", establishedAtUTC: "2026-09-20T00:00:00Z")
    return try CanonicalJSONEncoders.canonical().encode(record) + Data([0x0A])
  }

  private static func replacing(_ data: Data, _ original: String, with replacement: String) -> Data {
    let text = String(decoding: data, as: UTF8.self)
    precondition(text.contains(original), "the recorded bytes name \(original)")
    return Data(text.replacingOccurrences(of: original, with: replacement).utf8)
  }

  private static func seed(
    _ operation: RuntimeOperationReference, requestID: String
  ) throws -> Data {
    let request = try RuntimeOperationRequest(
      requestID: requestID, idempotencyKey: "\(requestID)-key",
      target: DurableTargetReference(targetID: targetID, expectedBindingRevision: 2),
      operation: operation,
      inputs: [
        "imageBundleLease": .string("artifact-lease-flash-host"),
        "profileReference": .string("dayu200"),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }

  private func input(_ name: String, _ bytes: Data) -> String {
    let path = "inputs/\(name)"
    if let existing = files[path] {
      precondition(existing == bytes, "\(path) names one input")
    }
    files[path] = bytes
    return path
  }

  // MARK: - Setup actions, performed here and recorded for the replay

  private func write(_ path: String, input name: String, _ bytes: Data, mode: Int = 0o600) throws {
    let recorded = input(name, bytes)
    let url = Self.root.appending(path: path)
    try? FileManager.default.removeItem(at: url)
    guard FileManager.default.createFile(atPath: url.path, contents: bytes),
      chmod(url.path, mode_t(mode)) == 0
    else { throw CocoaError(.fileWriteUnknown) }
    setup.append(
      .object([
        "action": .string("write"), "path": .string(path), "input": .string(recorded),
        "mode": .string(String(mode, radix: 8)),
      ]))
  }

  private func remove(_ path: String) throws {
    try FileManager.default.removeItem(at: Self.root.appending(path: path))
    setup.append(.object(["action": .string("remove"), "path": .string(path)]))
  }

  private func mode(_ path: String, _ mode: Int) throws {
    guard chmod(Self.root.appending(path: path).path, mode_t(mode)) == 0 else {
      throw POSIXError(.EPERM)
    }
    setup.append(
      .object([
        "action": .string("chmod"), "path": .string(path),
        "mode": .string(String(mode, radix: 8)),
      ]))
  }

  private func link(_ path: String, to destination: String) throws {
    try FileManager.default.createSymbolicLink(
      atPath: Self.root.appending(path: path).path, withDestinationPath: destination)
    setup.append(
      .object([
        "action": .string("symlink"), "path": .string(path), "to": .string(destination),
      ]))
  }

  private func usb(_ devices: [RockchipProductUSBIdentity]?, _ census: Census) {
    census.set(devices)
    setup.append(
      .object([
        "action": .string("usb"),
        "devices": devices.map { .array($0.map(Self.json)) } ?? .null,
      ]))
  }

  // MARK: - Exchanges

  /// Every file of the Application Support root outside the state and
  /// engine directories, with its kind, mode and size, recorded byte for
  /// byte under `prefix`.
  private func applicationSupportFiles(_ prefix: String) throws -> JSONValue {
    var listing: [JSONValue] = []
    let manager = FileManager.default
    for path in try manager.subpathsOfDirectory(atPath: Self.root.path).sorted()
    where !["state", "engine"].contains(where: { path == $0 || path.hasPrefix("\($0)/") }) {
      let url = Self.root.appending(path: path)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
      let kind: String
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR: kind = "directory"
      case S_IFLNK: kind = "link"
      default: kind = "file"
      }
      listing.append(
        .object([
          "path": .string(path), "kind": .string(kind),
          "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
          "bytes": .integer(Int64(metadata.st_size)),
        ]))
      if kind == "file" { files["\(prefix)/\(path)"] = try Data(contentsOf: url) }
    }
    return .array(listing)
  }

  /// The answer as recorded: the pager's random revision and cursor named,
  /// not valued.
  private func labelled(_ answer: JSONValue, exchange: Int) -> JSONValue {
    guard case .object(var fields) = HDCOracleHarness.revisionIndependent(answer),
      case .object(var result)? = fields["result"],
      case .string(let cursor)? = result["nextCursor"]
    else { return HDCOracleHarness.revisionIndependent(answer) }
    cursors[exchange] = cursor
    result["nextCursor"] = .string("<nextCursor-\(exchange)>")
    fields["result"] = .object(result)
    return .object(fields)
  }

  /// One request through the handler, recorded with the setup performed
  /// before it; `expect` is the answer's error code, or nil for success.
  @discardableResult
  private func exchange(
    _ name: String, _ method: String, _ params: [String: JSONValue],
    expect: String?, handler: RuntimeControlPlaneHandler, recordFiles: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws -> JSONValue {
    let index = exchanges.count + 1
    var sent = params
    for (key, value) in params {
      if case .string(let text) = value, text.hasPrefix("<nextCursor-"),
        let origin = Int(text.dropFirst("<nextCursor-".count).dropLast()),
        let cursor = cursors[origin]
      {
        sent[key] = .string(cursor)
      }
    }
    let answer = try await HDCOracleHarness.send(
      handler, method, sent, frameID: "flash-host-reads-\(index)")
    guard case .object(let fields) = answer else { throw CocoaError(.coderInvalidValue) }
    if let expect {
      guard case .object(let error)? = fields["error"] else {
        XCTFail("\(name) was answered, not refused with \(expect)", file: file, line: line)
        return answer
      }
      XCTAssertEqual(error["code"], .string(expect), "\(name): \(answer)", file: file, line: line)
    } else {
      XCTAssertEqual(fields["ok"], .bool(true), "\(name): \(answer)", file: file, line: line)
    }
    var record: [String: JSONValue] = [
      "index": .integer(Int64(index)), "name": .string(name), "method": .string(method),
      "params": .object(params), "setup": .array(setup),
      "answer": labelled(answer, exchange: index),
    ]
    setup = []
    if recordFiles {
      record["files"] = try applicationSupportFiles(String(format: "steps/%02d-%@", index, name))
    }
    exchanges.append(.object(record))
    return answer
  }

  // MARK: - The oracle

  func testSwiftAnswersTheFlashHostReadsTheRustDaemonReplays() async throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EACCES) }
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }
    let recording = ProcessInfo.processInfo.environment[Self.recordVariable] != nil

    let census = Census()
    let targetStore = try RuntimeTargetStore(
      directoryURL: Self.state.appending(path: "targets", directoryHint: .isDirectory))
    let reconciler = ProductRockchipPostFlashAliasReconciler(
      targetStore: targetStore,
      postFlashStore: RockchipPostFlashHDCBindingStore(rootURL: Self.root),
      usbProbe: RockchipProductUSBProbe(identitySource: census.read),
      nowUTC: { Self.nowUTC })
    let driver = Driver()
    let clock = Clock(Self.nowUTC)
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: Self.state, driver: driver, nowUTC: clock.now)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: Self.root.appending(path: "engine/capabilities"))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: Self.root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: RuntimeAgentExecutionContractTests.Dispatcher(),
      capabilityStore: capabilities, nowUTC: { Self.nowUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { Self.nowUTC }, targetStore: targetStore,
      rockchipPostFlashAliasReconciler: reconciler,
      debugInvocationController: controller)

    try await reconcileAlias(handler: handler, census: census)
    let documents =
      recording
      ? try await recordInvocations(controller: controller, driver: driver, clock: clock)
      : try recordedInvocations()
    try await readInvocations(handler: handler, documents: documents)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["exchanges": .array(exchanges)])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("FlashHostReadsOracleContractTests"),
          "applicationSupportRoot": .string(Self.root.path),
          "stateDirectory": .string(Self.state.path),
          "nowUTC": .string(Self.nowUTC),
          "owners": .array([
            .string("ProductRockchipPostFlashAliasReconciler"),
            .string("RuntimeDebugInvocationController"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  // MARK: flash.reconcile-alias

  private func reconcileAlias(
    handler: RuntimeControlPlaneHandler, census: Census
  ) async throws {
    let request: (Int) -> [String: JSONValue] = {
      ["targetId": .string(Self.targetID), "expectedBindingRevision": .integer(Int64($0))]
    }
    let targets = "state/targets/targets.json"
    let archive = "post-flash-superseded-20260920T000000Z.json"
    let board = Self.hdcNormal(Self.hdcKey, at: "42")
    // Only the registered DAYU200 counts: another USB device beside it is
    // not a second board.
    let unrelated = RockchipProductUSBIdentity(
      serial: "unrelated-serial", vendorID: 0x05ac, productID: 0x12a8, topology: "99",
      productName: "iPhone")

    try await exchange(
      "alias.noParameters", "flash.reconcile-alias", [:], expect: "invalidParams",
      handler: handler, recordFiles: true)
    try await exchange(
      "alias.noRevision", "flash.reconcile-alias", ["targetId": .string(Self.targetID)],
      expect: "invalidParams", handler: handler, recordFiles: true)
    try await exchange(
      "alias.zeroRevision", "flash.reconcile-alias", request(0), expect: "invalidParams",
      handler: handler, recordFiles: true)
    try await exchange(
      "alias.noTarget", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(targets, input: "targets-revision-2.json", try Self.targets(revision: 2))
    try await exchange(
      "alias.staleRevision", "flash.reconcile-alias", request(3), expect: "rejected",
      handler: handler, recordFiles: true)
    try await exchange(
      "alias.emptyTarget", "flash.reconcile-alias",
      ["targetId": .string(""), "expectedBindingRevision": .integer(2)],
      expect: "rejected", handler: handler, recordFiles: true)
    usb([], census)
    try await exchange(
      "alias.nothingAttached", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    usb([Self.loader(Self.otherKey, at: "17")], census)
    try await exchange(
      "alias.loaderOnly", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    usb([board, Self.hdcNormal(Self.otherKey, at: "43")], census)
    try await exchange(
      "alias.twoBoards", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    usb(nil, census)
    try await exchange(
      "alias.registryUnavailable", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    usb([unrelated, board], census)
    try await exchange(
      "alias.nothingStored", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(Self.aliasFile, input: "alias-revision-2.json", try Self.alias(revision: 2))
    try await exchange(
      "alias.notAhead", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(
      Self.aliasFile, input: "alias-revision-4-topology-43.json",
      try Self.alias(revision: 4, topology: "43"))
    try await exchange(
      "alias.otherTopology", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(
      Self.aliasFile, input: "alias-revision-4-other-loader.json",
      try Self.alias(revision: 4, loader: Self.otherLoaderIdentity))
    try await exchange(
      "alias.otherLoader", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(Self.aliasFile, input: "alias-revision-4.json", try Self.alias(revision: 4))
    try write(archive, input: "alias-revision-3.json", try Self.alias(revision: 3))
    try await exchange(
      "alias.archiveTaken", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try remove(archive)
    try await exchange(
      "alias.reconciled", "flash.reconcile-alias", request(2), expect: nil,
      handler: handler, recordFiles: true)
    try await exchange(
      "alias.repeated", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try mode(Self.aliasFile, 0o644)
    try await exchange(
      "alias.sharedMode", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(Self.aliasFile, input: "alias-not-json.json", Data("not json\n".utf8))
    try await exchange(
      "alias.undecodable", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(
      Self.aliasFile, input: "alias-schema-2.json",
      Self.replacing(
        try Self.alias(revision: 4), "\"schemaVersion\":\"1.0.0\"",
        with: "\"schemaVersion\":\"2.0.0\""))
    try await exchange(
      "alias.otherSchema", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try write(Self.aliasFile, input: "empty", Data())
    try await exchange(
      "alias.empty", "flash.reconcile-alias", request(2), expect: "rejected",
      handler: handler, recordFiles: true)
    try remove(Self.aliasFile)
    try remove(targets)
  }

  // MARK: Flash invocation documents

  /// The nine documents the controller writes, by label, and their bytes.
  private struct Documents {
    let identities: [String: String]
    let bytes: [String: Data]
  }

  private static let labels = [
    "active", "observed", "stopped", "recovering", "succeeded", "blocked", "refused",
    "fullRestore", "expired",
  ]

  private func recordInvocations(
    controller: RuntimeDebugInvocationController, driver: Driver, clock: Clock
  ) async throws -> Documents {
    let dayu200 = RuntimeOperationReference(id: "flash.dayu200")
    let fullRestore = RuntimeOperationReference(id: "flash.full-restore", version: 1)
    let observe = Data(#"{"schemaVersion":"1.0.0","action":"observePinnedRequest"}"#.utf8)
    let execute = Data(#"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#.utf8)
    let stop = Data(
      #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"operator.cancelled"}"#.utf8)
    func provenance(_ ordinal: Int) throws -> RuntimeDebugCandidateProvenance {
      try RuntimeDebugCandidateProvenance(
        sourceSHA256: String(format: "%064x", ordinal),
        buildSHA256: String(format: "%064x", ordinal + 100))
    }
    var identities: [String: String] = [:]
    func start(
      _ label: String, at time: String, _ operation: RuntimeOperationReference
    ) async throws -> String {
      clock.set(time)
      let status = try await controller.start(
        seedRequestData: try Self.seed(operation, requestID: "flash-host-\(label)"))
      identities[label] = status.invocationID
      return status.invocationID
    }

    _ = try await start("active", at: "2026-09-25T00:00:00Z", dayu200)
    let observed = try await start("observed", at: "2026-09-25T00:01:00Z", dayu200)
    clock.set("2026-09-25T00:01:30Z")
    _ = try await controller.evaluate(
      invocationID: observed, actionData: observe, provenance: try provenance(1))
    let stopped = try await start("stopped", at: "2026-09-25T00:02:00Z", dayu200)
    clock.set("2026-09-25T00:02:30Z")
    _ = try await controller.evaluate(
      invocationID: stopped, actionData: stop, provenance: try provenance(2))
    let recovering = try await start("recovering", at: "2026-09-25T00:03:00Z", dayu200)
    await driver.script([.safeToReflash, .outcomeUnknown])
    clock.set("2026-09-25T00:03:10Z")
    _ = try await controller.evaluate(
      invocationID: recovering, actionData: execute, provenance: try provenance(3))
    clock.set("2026-09-25T00:03:20Z")
    _ = try await controller.evaluate(
      invocationID: recovering, actionData: execute, provenance: try provenance(4))
    for (label, time, outcome) in [
      ("succeeded", "2026-09-25T00:04:00Z", RuntimeDebugExecutionOutcome.succeeded),
      ("blocked", "2026-09-25T00:05:00Z", .failedKnown),
      ("refused", "2026-09-25T00:06:00Z", .refused),
    ] {
      let invocation = try await start(label, at: time, dayu200)
      await driver.script([outcome])
      clock.set(String(time.dropLast(3)) + "10Z")
      _ = try await controller.evaluate(
        invocationID: invocation, actionData: execute, provenance: try provenance(5))
    }
    // The same creation time as `refused`: the list orders the two by
    // identity.
    _ = try await start("fullRestore", at: "2026-09-25T00:06:00Z", fullRestore)
    let expired = try await start("expired", at: "2026-09-25T00:07:00Z", dayu200)
    clock.set("2026-09-25T04:08:00Z")
    do {
      _ = try await controller.evaluate(
        invocationID: expired, actionData: observe, provenance: try provenance(6))
      XCTFail("an evaluation past the invocation's lifetime must expire it")
    } catch RuntimeDebugInvocationError.invocationExpired {}

    var bytes: [String: Data] = [:]
    for label in Self.labels {
      let path = "\(Self.invocations)/\(identities[label]!).json"
      bytes[label] = try Data(contentsOf: Self.root.appending(path: path))
      try FileManager.default.removeItem(at: Self.root.appending(path: path))
    }
    return Documents(identities: identities, bytes: bytes)
  }

  private func recordedInvocations() throws -> Documents {
    let index = try JSONDecoder().decode(
      [String: String].self,
      from: Data(contentsOf: Self.oracle.appending(path: "inputs/invocations/index.json")))
    var bytes: [String: Data] = [:]
    for label in Self.labels {
      bytes[label] = try Data(
        contentsOf: Self.oracle.appending(path: "inputs/invocations/\(index[label]!).json"))
    }
    return Documents(identities: index, bytes: bytes)
  }

  private func readInvocations(
    handler: RuntimeControlPlaneHandler, documents: Documents
  ) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    _ = input("invocations/index.json", try encoder.encode(documents.identities) + Data("\n".utf8))
    let list = "recovery.flash-invocation.list"
    let status: (String) -> [String: JSONValue] = { ["invocationId": .string($0)] }
    func path(_ identity: String) -> String { "\(Self.invocations)/\(identity).json" }

    try await exchange("list.empty", list, [:], expect: nil, handler: handler)
    for label in Self.labels {
      let identity = documents.identities[label]!
      try write(path(identity), input: "invocations/\(identity).json", documents.bytes[label]!)
    }
    try await exchange("list.all", list, [:], expect: nil, handler: handler)
    let first = exchanges.count + 1
    try await exchange("list.firstPage", list, ["pageSize": .integer(4)], expect: nil, handler: handler)
    try await exchange(
      "list.secondPage", list,
      ["pageSize": .integer(4), "cursor": .string("<nextCursor-\(first)>")],
      expect: nil, handler: handler)
    try await exchange(
      "list.lastPage", list,
      ["pageSize": .integer(4), "cursor": .string("<nextCursor-\(first + 1)>")],
      expect: nil, handler: handler)
    try await exchange(
      "list.cursorOfAnotherQuery", list,
      ["pageSize": .integer(3), "cursor": .string("<nextCursor-\(first)>")],
      expect: "invalidCursor", handler: handler)
    try await exchange(
      "list.zeroPageSize", list, ["pageSize": .integer(0)], expect: "invalidParams",
      handler: handler)
    try await exchange(
      "list.pageSizeOverBound", list, ["pageSize": .integer(1001)], expect: "invalidParams",
      handler: handler)
    try await exchange(
      "list.cursorOverBound", list, ["cursor": .string(String(repeating: "a", count: 257))],
      expect: "invalidCursor", handler: handler)
    try await exchange(
      "list.malformedCursor", list, ["cursor": .string("not-a-cursor")],
      expect: "invalidCursor", handler: handler)

    for label in Self.labels {
      try await exchange(
        "status.\(label)", "debug.status", status(documents.identities[label]!), expect: nil,
        handler: handler)
    }
    try await exchange("status.noParameters", "debug.status", [:], expect: "invalidParams", handler: handler)
    try await exchange(
      "status.unknown", "debug.status", status("debug-00000000-0000-4000-8000-000000000000"),
      expect: "notFound", handler: handler)
    try await exchange(
      "status.invalidIdentity", "debug.status", status("Debug-00000000"), expect: "notFound",
      handler: handler)
    try await exchange(
      "status.identityOverBound", "debug.status", status("d" + String(repeating: "a", count: 128)),
      expect: "notFound", handler: handler)

    // Documents the reads refuse, each derived from a recorded one and
    // present alone.
    let active = documents.identities["active"]!
    let activeBytes = documents.bytes["active"]!
    let observedBytes = documents.bytes["observed"]!
    let observedIdentity = documents.identities["observed"]!
    func renamed(_ data: Data, from identity: String, to other: String) -> Data {
      Self.replacing(data, "\"invocationID\":\"\(identity)\"", with: "\"invocationID\":\"\(other)\"")
    }
    let corrupt: [(label: String, bytes: Data, expect: String, list: Bool)] = [
      (
        "unknownKey",
        Self.replacing(
          renamed(activeBytes, from: active, to: "debug-corrupt-unknownkey"), "{\"baseline",
          with: "{\"unexpected\":true,\"baseline"),
        "notFound", true
      ),
      (
        "duplicateMember",
        Self.replacing(
          renamed(activeBytes, from: active, to: "debug-corrupt-duplicatemember"), "{\"baseline",
          with: "{\"state\":\"active\",\"baseline"),
        "notFound", false
      ),
      (
        "explicitNull",
        Self.replacing(
          renamed(observedBytes, from: observedIdentity, to: "debug-corrupt-explicitnull"),
          "\"ordinal\":1", with: "\"jobID\":null,\"ordinal\":1"),
        "notFound", false
      ),
      (
        "otherSchema",
        Self.replacing(
          renamed(activeBytes, from: active, to: "debug-corrupt-otherschema"),
          "\"schemaVersion\":\"1.0.0\",\"seedRequest\"",
          with: "\"schemaVersion\":\"2.0.0\",\"seedRequest\""),
        "recordUnreadable", false
      ),
      ("otherIdentity", activeBytes, "recordUnreadable", false),
      (
        "epochsOverBudget",
        Self.replacing(
          renamed(activeBytes, from: active, to: "debug-corrupt-epochsoverbudget"),
          "\"destructiveEpochsUsed\":0", with: "\"destructiveEpochsUsed\":17"),
        "recordUnreadable", false
      ),
    ]
    for entry in corrupt {
      let identity = "debug-corrupt-\(entry.label.lowercased())"
      try write(path(identity), input: "invocations/corrupt-\(entry.label).json", entry.bytes)
      try await exchange(
        "status.\(entry.label)", "debug.status", status(identity), expect: entry.expect,
        handler: handler)
      if entry.list {
        try await exchange("list.\(entry.label)", list, [:], expect: entry.expect, handler: handler)
      }
      try remove(path(identity))
    }
    let shared = "debug-corrupt-sharedmode"
    try write(
      path(shared), input: "invocations/corrupt-sharedMode.json",
      renamed(activeBytes, from: active, to: shared), mode: 0o644)
    try await exchange(
      "status.sharedMode", "debug.status", status(shared), expect: "recordUnreadable",
      handler: handler)
    try await exchange("list.sharedMode", list, [:], expect: "recordUnreadable", handler: handler)
    try remove(path(shared))
    try write(path("debug-corrupt-empty"), input: "empty", Data())
    try await exchange(
      "status.empty", "debug.status", status("debug-corrupt-empty"), expect: "recordUnreadable",
      handler: handler)
    try remove(path("debug-corrupt-empty"))
    try link(path("debug-corrupt-link"), to: "/etc/hosts")
    try await exchange(
      "status.link", "debug.status", status("debug-corrupt-link"), expect: "recordUnreadable",
      handler: handler)
    try await exchange("list.link", list, [:], expect: "recordUnreadable", handler: handler)
    try remove(path("debug-corrupt-link"))
    try write("\(Self.invocations)/.DS_Store", input: "ds-store", Data([0x00]))
    try await exchange("list.unknownEntry", list, [:], expect: "recordUnreadable", handler: handler)
    try remove("\(Self.invocations)/.DS_Store")
    try write(
      "\(Self.invocations)/Bad.json", input: "invocations/corrupt-invalidIdentity.json",
      activeBytes)
    try await exchange("list.invalidIdentity", list, [:], expect: "recordUnreadable", handler: handler)
    try remove("\(Self.invocations)/Bad.json")
    try mode(Self.invocations, 0o755)
    try await exchange(
      "status.sharedDirectory", "debug.status", status(active), expect: "recordUnreadable",
      handler: handler)
    try await exchange(
      "list.sharedDirectory", list, [:], expect: "recordUnreadable", handler: handler)
    try mode(Self.invocations, 0o700)
    try await exchange("list.restored", list, [:], expect: nil, handler: handler)
  }
}
