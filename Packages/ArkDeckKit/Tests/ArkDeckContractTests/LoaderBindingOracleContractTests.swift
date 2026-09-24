// Shared Swift oracle for the Rust Loader binding (CHG-2026-074, TASK-XPA-017, milestone M4).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `flash.bind-current-loader` through the daemon's control-plane
/// handler, composed with the owner the daemon composes for it:
/// `ProductRockchipLoaderBindingCoordinator` over the Target store, the
/// product binding store of the Application Support root, and the Runtime's
/// typed action records under its `Agentd/rockchip-runtime`, from which it
/// proves a historical Target's reactivation.
///
/// What a host cannot fix is injected, and nothing else: the USB census the
/// coordinator reads in place of the I/O Registry, and ArkForge's half of the
/// dual-source Loader observation (confirmed, at another port, or refused
/// with a text). No device, ArkForge daemon, HDC or daemon process, and no
/// Job: the engine holds none, so no enter-Loader transition is settled.
///
/// The exchanges run in order over one root, each after the setup it names
/// (a file written from `inputs/` or removed, a directory made, the census,
/// the observation), and each records afterwards every file of the
/// Application Support root but the engine's, the state directory's and the
/// reactivation records, with the Target document, byte for byte
/// (`steps/`): the binding and its lock, and the Target the bind advanced.
///
/// Every request is one a caller may send under the published request
/// schema; a parameter the handler refuses by name (a revision spelled as a
/// string) would publish that name in it, so those refusals are the Rust
/// replay's own.
///
/// Record a new oracle with
/// `ARKDECK_RUST_LOADER_BINDING_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class LoaderBindingOracleContractTests: XCTestCase {
  /// The census the coordinator reads in place of the host's I/O Registry;
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

  /// A refusal whose description is exactly what the daemon interpolates.
  private struct Refusal: Error, CustomStringConvertible {
    let description: String
  }

  /// ArkForge's half of the dual-source Loader observation, scripted: the
  /// asked identity at the asked port, the asked identity at another port, or
  /// a refusal.
  private final class Loader: ArkForgeLoaderObserving, @unchecked Sendable {
    enum Script {
      case confirm
      case port(String)
      case refuse(String)
    }

    private let lock = NSLock()
    private var script = Script.confirm

    func set(_ script: Script) { lock.withLock { self.script = script } }

    func observeLoader(
      stableIdentitySHA256: String, expectedUSBTopology: String?, requestID: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      switch lock.withLock({ script }) {
      case .confirm:
        return RockchipRuntimeLoaderIdentity(
          serialDigestSHA256: stableIdentitySHA256, topology: expectedUSBTopology ?? "")
      case .port(let topology):
        return RockchipRuntimeLoaderIdentity(
          serialDigestSHA256: stableIdentitySHA256, topology: topology)
      case .refuse(let reason):
        throw Refusal(description: reason)
      }
    }
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/loader-binding", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_LOADER_BINDING_RECORD"
  /// The Application Support root: the binding lives here, the state
  /// directory and the reactivation records below it, as the daemon
  /// composes them. Not below `/private`: the reactivation records' root must
  /// be its own standardized path, and Foundation standardizes
  /// `/private/tmp/…` to `/tmp/…`.
  private static let root = URL(
    filePath: "/tmp/arkdeck-loader-binding-oracle", directoryHint: .isDirectory)
  private static let lockPath = "/tmp/arkdeck-loader-binding-oracle.lock"
  private static let state = root.appending(path: "state", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-25T00:00:00Z"
  private static let targets = "state/targets/targets.json"
  private static let binding = "rockchip-binding.json"
  private static let records = "Agentd/rockchip-runtime"

  private static let boardA = "TGT-BOARD-A"
  private static let boardB = "TGT-BOARD-B"
  /// Board A: its HDC serial and port in its normal personality, its Loader
  /// serial and port, and the Loader serial it drifts to.
  private static let hdcA = "1501ffff00000000000000000000cafe"
  private static let normalA = "18874368"
  private static let loaderA = "loader-serial-0451"
  private static let loaderPortA = "17956864"
  private static let driftedLoaderA = "loader-serial-0999"
  /// Board B, a second board on the bench, in its normal personality.
  private static let hdcB = "1501ffff0000000000000000000beef1"
  private static let normalB = "19922944"
  /// Another connect key, and the post-flash alias Target's.
  private static let otherKey = "1501ffff000000000000000000000003"
  private static let aliasKey = "1501ffff000000000000000000000a1a"
  /// The provider executable the reactivation records name.
  private static let provider = String(repeating: "7", count: 64)

  private var files: [String: Data] = [:]
  private var exchanges: [JSONValue] = []
  private var setup: [JSONValue] = []

  private static func digest(_ text: String) -> String {
    SHA256Hex.string(of: Data(text.utf8))
  }

  private static func hdcNormal(_ serial: String, at topology: String) -> RockchipProductUSBIdentity
  {
    RockchipProductUSBIdentity(
      serial: serial, vendorID: 0x2207, productID: 0x5000, topology: topology,
      productName: "\"HDC Device\"", registryEntryID: 0x1_0000_0042)
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

  private static func target(
    _ id: String, identity: String, revision: Int, connectKey: String
  ) -> JSONValue {
    .object([
      "targetID": .string(id),
      "stablePhysicalIdentitySHA256": .string(identity),
      "bindingRevision": .integer(Int64(revision)),
      "connectKey": .string(connectKey),
      "toolVersion": .string("3.2.0f"),
      "adoptedAtUTC": .string("2026-09-01T00:00:00Z"),
    ])
  }

  private static func targetsDocument(
    _ records: [JSONValue], resolutions: [JSONValue]? = nil
  ) throws -> Data {
    var document: [String: JSONValue] = [
      "schemaVersion": .string("1.0.0"), "targets": .array(records),
    ]
    if let resolutions { document["aliasResolutions"] = .array(resolutions) }
    return try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document))
  }

  /// A proven post-flash alias resolution naming `canonical` at its current
  /// identity and revision, digested as the Target store digests it.
  private static func aliasResolution(
    alias: String, aliasIdentity: String, canonical: String, canonicalIdentity: String,
    canonicalRevision: Int
  ) throws -> JSONValue {
    let job = "job-flash-alias-1"
    let seed = digest([alias, canonical, job].joined(separator: "\n"))
    var material: [String: JSONValue] = [
      "resolutionID": .string("target-alias-resolution-\(seed.prefix(32))"),
      "aliasTargetID": .string(alias),
      "aliasStableIdentitySHA256": .string(aliasIdentity),
      "aliasBindingRevision": .integer(1),
      "canonicalTargetID": .string(canonical),
      "canonicalStableIdentitySHA256": .string(canonicalIdentity),
      "canonicalBindingRevision": .integer(Int64(canonicalRevision)),
      "routedHDCIdentitySHA256": .string(aliasIdentity),
      "routedUSBTopology": .string(normalA),
      "establishingFlashJobID": .string(job),
      "establishingFlashPlanDigestSHA256": .string(String(repeating: "c", count: 64)),
      "confirmedStepIDs": .array(
        [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback", "reboot-device",
          "wait-for-hdc", "rebind-and-verify-build",
        ].map(JSONValue.string)),
      "coveredUnknownIntents": .array([]),
      "establishedAtUTC": .string("2026-09-20T00:00:00Z"),
    ]
    material["resolutionSHA256"] = .string(
      SHA256Hex.string(
        of: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(material))))
    return .object(material)
  }

  /// The binding as the store writes it: sorted keys and a newline.
  private static func bindingDocument(
    revision: Int, serial: String, topology: String, evidence: [String]
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(
      RockchipProductBindingSnapshot(
        revision: revision, serial: serial, usbTopology: topology, evidence: evidence))
      + Data([0x0A])
  }

  /// What `RockchipProductBindingBootstrap` installs for a board seen in its
  /// normal personality: revision 1, its serial's digest.
  private static func installed(_ serial: String, readback: Bool = true) -> [String] {
    (readback ? ["product:e0-iokit-single-dayu200-readback"] : [])
      + [
        "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
        "identity:serial-sha256=\(digest(serial))",
      ]
  }

  /// A typed action as the Runtime records it, and its canonical digest.
  private static func action(
    _ kind: String, _ arguments: [String: JSONValue]
  ) throws -> (JSONValue, String) {
    let action = JSONValue.object(["kind": .string(kind), "arguments": .object(arguments)])
    return (action, SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(action)))
  }

  private static func intent(
    job: String, step: String, target: String, revision: Int, identity: String,
    kind: String, arguments: [String: JSONValue]
  ) throws -> Data {
    let (action, actionSHA256) = try action(kind, arguments)
    return try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "schemaVersion": .string("1.0.0"), "jobID": .string(job), "stepID": .string(step),
        "targetID": .string(target), "bindingRevision": .integer(Int64(revision)),
        "stableIdentitySHA256": .string(identity),
        "providerExecutableSHA256": .string(provider),
        "actionSHA256": .string(actionSHA256), "action": action,
      ])) + Data([0x0A])
  }

  private static func receipt(
    job: String, step: String, target: String, revision: Int, identity: String,
    kind: String, arguments: [String: JSONValue], summary: [String: String]
  ) throws -> Data {
    let (_, actionSHA256) = try action(kind, arguments)
    return try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "schemaVersion": .string("1.0.0"), "jobID": .string(job), "stepID": .string(step),
        "targetID": .string(target), "bindingRevision": .integer(Int64(revision)),
        "stableIdentitySHA256": .string(identity),
        "providerExecutableSHA256": .string(provider),
        "actionSHA256": .string(actionSHA256),
        "summary": .object(summary.mapValues(JSONValue.string)),
        "stdoutSHA256": .string(digest("")), "stdoutByteCount": .integer(0),
        "stderrSHA256": .string(digest("")), "stderrByteCount": .integer(0),
        "stdoutTruncated": .bool(false), "subprocessCount": .integer(1),
      ])) + Data([0x0A])
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

  private func makeDirectory(_ path: String) throws {
    let url = Self.root.appending(path: path)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    setup.append(
      .object(["action": .string("mkdir"), "path": .string(path), "mode": .string("700")]))
  }

  private func usb(_ devices: [RockchipProductUSBIdentity]?, _ census: Census) {
    census.set(devices)
    setup.append(
      .object([
        "action": .string("usb"),
        "devices": devices.map { .array($0.map(Self.json)) } ?? .null,
      ]))
  }

  private func observation(_ script: Loader.Script, _ loader: Loader) {
    loader.set(script)
    switch script {
    case .confirm:
      setup.append(.object(["action": .string("loader"), "script": .string("confirm")]))
    case .port(let topology):
      setup.append(
        .object([
          "action": .string("loader"), "script": .string("port"), "topology": .string(topology),
        ]))
    case .refuse(let reason):
      setup.append(
        .object([
          "action": .string("loader"), "script": .string("refuse"), "refusal": .string(reason),
        ]))
    }
  }

  // MARK: - Exchanges

  /// Every file of the Application Support root but the engine's, the state
  /// directory's and the reactivation records, then the Target document,
  /// with its kind, mode and size, recorded byte for byte under `prefix`.
  private func boundFiles(_ prefix: String) throws -> JSONValue {
    var listing: [JSONValue] = []
    let manager = FileManager.default
    for path in try manager.subpathsOfDirectory(atPath: Self.root.path).sorted()
    where ["engine", "state", "Agentd"].allSatisfy({ path != $0 && !path.hasPrefix("\($0)/") })
      || path == Self.targets
    {
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

  /// One request through the handler, recorded with the setup performed
  /// before it and the files after it; `expect` is the answer's error code,
  /// or nil for success.
  @discardableResult
  private func exchange(
    _ name: String, _ params: [String: JSONValue], expect: String?,
    handler: RuntimeControlPlaneHandler, file: StaticString = #filePath, line: UInt = #line
  ) async throws -> JSONValue {
    let index = exchanges.count + 1
    let answer = try await HDCOracleHarness.send(
      handler, "flash.bind-current-loader", params, frameID: "loader-binding-\(index)")
    guard case .object(let fields) = answer else { throw CocoaError(.coderInvalidValue) }
    if let expect {
      guard case .object(let error)? = fields["error"] else {
        XCTFail("\(name) was answered, not refused with \(expect): \(answer)", file: file, line: line)
        return answer
      }
      XCTAssertEqual(error["code"], .string(expect), "\(name): \(answer)", file: file, line: line)
    } else {
      XCTAssertEqual(fields["ok"], .bool(true), "\(name): \(answer)", file: file, line: line)
    }
    exchanges.append(
      .object([
        "index": .integer(Int64(index)), "name": .string(name),
        "method": .string("flash.bind-current-loader"), "params": .object(params),
        "setup": .array(setup), "answer": answer,
        "files": try boundFiles(String(format: "steps/%02d-%@", index, name)),
      ]))
    setup = []
    return answer
  }

  private func assertBound(
    _ answer: JSONValue, updated: Bool, previous: Int, current: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .object(let fields) = answer, case .object(let result)? = fields["result"] else {
      return XCTFail("no receipt: \(answer)", file: file, line: line)
    }
    XCTAssertEqual(result["updated"], .bool(updated), file: file, line: line)
    XCTAssertEqual(result["previousBindingRevision"], .integer(Int64(previous)), file: file, line: line)
    XCTAssertEqual(result["bindingRevision"], .integer(Int64(current)), file: file, line: line)
    XCTAssertEqual(result["settledJobId"], .null, file: file, line: line)
  }

  // MARK: - The oracle

  func testSwiftAnswersTheLoaderBindingTheRustDaemonReplays() async throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EACCES) }
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }

    let census = Census()
    let loader = Loader()
    let targetStore = try RuntimeTargetStore(
      directoryURL: Self.state.appending(path: "targets", directoryHint: .isDirectory))
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: targetStore,
      bindingStore: RockchipProductBindingStore(rootURL: Self.root),
      usbProbe: RockchipProductUSBProbe(identitySource: census.read),
      loaderObserver: loader)
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
      rockchipLoaderBindingCoordinator: coordinator)

    try await bindCurrentLoader(handler: handler, census: census, loader: loader)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["exchanges": .array(exchanges)])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("LoaderBindingOracleContractTests"),
          "applicationSupportRoot": .string(Self.root.path),
          "stateDirectory": .string(Self.state.path),
          "nowUTC": .string(Self.nowUTC),
          "owners": .array([.string("ProductRockchipLoaderBindingCoordinator")]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  // MARK: flash.bind-current-loader

  private func bindCurrentLoader(
    handler: RuntimeControlPlaneHandler, census: Census, loader: Loader
  ) async throws {
    let request: (String, Int) -> [String: JSONValue] = {
      ["targetId": .string($0), "expectedBindingRevision": .integer(Int64($1))]
    }
    let digest = Self.digest
    let boardALoader = Self.loader(Self.loaderA, at: Self.loaderPortA)
    let driftedLoader = Self.loader(Self.driftedLoaderA, at: Self.loaderPortA)
    let targetA1 = Self.target(
      Self.boardA, identity: digest(Self.hdcA), revision: 1, connectKey: Self.hdcA)
    let targetA2 = Self.target(
      Self.boardA, identity: digest(Self.loaderA), revision: 2, connectKey: Self.hdcA)
    let targetB1 = Self.target(
      Self.boardB, identity: digest(Self.hdcB), revision: 1, connectKey: Self.hdcB)
    let installedA = try Self.bindingDocument(
      revision: 1, serial: Self.hdcA, topology: Self.normalA, evidence: Self.installed(Self.hdcA))
    let unrelated = RockchipProductUSBIdentity(
      serial: "unrelated-serial", vendorID: 0x05ac, productID: 0x12a8, topology: "99",
      productName: "iPhone")

    // Refusals before anything is read.
    try await exchange("bind.noParameters", [:], expect: "invalidParams", handler: handler)
    try await exchange(
      "bind.noRevision", ["targetId": .string(Self.boardA)], expect: "invalidParams",
      handler: handler)
    try await exchange(
      "bind.zeroRevision", request(Self.boardA, 0), expect: "invalidParams", handler: handler)
    try await exchange(
      "bind.noTarget", request(Self.boardA, 1), expect: "rejected", handler: handler)
    try write(Self.targets, input: "targets-a1.json", try Self.targetsDocument([targetA1]))
    try await exchange(
      "bind.staleRevision", request(Self.boardA, 3), expect: "rejected", handler: handler)
    try await exchange("bind.emptyTarget", request("", 1), expect: "rejected", handler: handler)

    // Exactly one registered DAYU200, and a Loader confirmed by both sources.
    usb([], census)
    try await exchange(
      "bind.nothingAttached", request(Self.boardA, 1), expect: "rejected", handler: handler)
    usb([boardALoader, Self.hdcNormal(Self.hdcB, at: Self.normalB)], census)
    try await exchange(
      "bind.twoBoards", request(Self.boardA, 1), expect: "rejected", handler: handler)
    usb(nil, census)
    try await exchange(
      "bind.registryUnavailable", request(Self.boardA, 1), expect: "rejected", handler: handler)
    usb([unrelated], census)
    try await exchange(
      "bind.unrelatedOnly", request(Self.boardA, 1), expect: "rejected", handler: handler)
    usb([unrelated, boardALoader], census)
    observation(
      .refuse("arkforged discoverDevices is unavailable: DAEMON_UNAVAILABLE: no lane"), loader)
    try await exchange(
      "bind.loaderUnobserved", request(Self.boardA, 1), expect: "rejected", handler: handler)
    observation(.port("20000000"), loader)
    try await exchange(
      "bind.loaderElsewhere", request(Self.boardA, 1), expect: "rejected", handler: handler)
    observation(.confirm, loader)

    // The binding it replaces.
    try await exchange(
      "bind.bindingAbsent", request(Self.boardA, 1), expect: "rejected", handler: handler)
    try write(Self.binding, input: "binding-a-installed.json", installedA, mode: 0o644)
    try await exchange(
      "bind.bindingSharedMode", request(Self.boardA, 1), expect: "rejected", handler: handler)
    try write(Self.binding, input: "binding-a-installed.json", installedA)

    // The first cross-mode bind advances the Target to its Loader, and its
    // retries answer the same edge.
    assertBound(
      try await exchange(
        "bind.firstCrossMode", request(Self.boardA, 1), expect: nil, handler: handler),
      updated: true, previous: 1, current: 2)
    assertBound(
      try await exchange(
        "bind.firstCrossModeRetried", request(Self.boardA, 1), expect: nil, handler: handler),
      updated: false, previous: 1, current: 2)
    assertBound(
      try await exchange(
        "bind.boundRevisionRetried", request(Self.boardA, 2), expect: nil, handler: handler),
      updated: false, previous: 2, current: 2)
    usb([Self.hdcNormal(Self.hdcA, at: Self.normalA)], census)
    try await exchange(
      "bind.hdcNormalWithoutCrossMode", request(Self.boardA, 2), expect: "rejected",
      handler: handler)

    // A second board adopted at revision 1 takes the active binding over.
    usb([Self.hdcNormal(Self.hdcB, at: Self.normalB)], census)
    try write(
      Self.targets, input: "targets-a2-b1-twin.json",
      try Self.targetsDocument([
        targetA2, targetB1,
        Self.target(
          "TGT-TWIN", identity: digest(Self.hdcB), revision: 1, connectKey: Self.otherKey),
      ]))
    try await exchange(
      "bind.secondBoardAmbiguous", request(Self.boardB, 1), expect: "rejected", handler: handler)
    try write(
      Self.targets, input: "targets-a2-b1.json", try Self.targetsDocument([targetA2, targetB1]))
    assertBound(
      try await exchange(
        "bind.selectSecondBoard", request(Self.boardB, 1), expect: nil, handler: handler),
      updated: true, previous: 1, current: 1)
    assertBound(
      try await exchange(
        "bind.selectSecondBoardRetried", request(Self.boardB, 1), expect: nil, handler: handler),
      updated: false, previous: 1, current: 1)

    // Board A's Target is reactivated only from the Runtime's own records.
    usb([boardALoader], census)
    try await exchange(
      "bind.reactivationUnproved", request(Self.boardA, 2), expect: "rejected", handler: handler)
    let job = "job-reactivation-1"
    let jobDirectory = "\(Self.records)/\(job)"
    try makeDirectory("Agentd")
    try makeDirectory(Self.records)
    try makeDirectory(jobDirectory)
    try makeDirectory("\(jobDirectory)/wait-for-hdc")
    try makeDirectory("\(jobDirectory)/reconcile-enter-loader-mode-1")
    try write(
      "\(jobDirectory)/wait-for-hdc/intent.json", input: "record-wait-for-hdc-intent.json",
      try Self.intent(
        job: job, step: "wait-for-hdc", target: Self.boardA, revision: 2,
        identity: digest(Self.loaderA), kind: "rockchip.waitForHDCReconnect",
        arguments: ["connectKey": .string(Self.hdcA)]))
    let reconcile: [String: JSONValue] = ["connectKey": .string(Self.hdcA)]
    try write(
      "\(jobDirectory)/reconcile-enter-loader-mode-1/intent.json",
      input: "record-reconcile-intent.json",
      try Self.intent(
        job: job, step: "reconcile-enter-loader-mode-1", target: Self.boardA, revision: 1,
        identity: digest(Self.hdcA), kind: "rockchip.observeHDCNormalUSB", arguments: reconcile))
    try write(
      "\(jobDirectory)/reconcile-enter-loader-mode-1/receipt.json",
      input: "record-reconcile-receipt.json",
      try Self.receipt(
        job: job, step: "reconcile-enter-loader-mode-1", target: Self.boardA, revision: 1,
        identity: digest(Self.hdcA), kind: "rockchip.observeHDCNormalUSB", arguments: reconcile,
        summary: [
          "usbState": "hdc-normal", "hdcNormalIdentitySha256": digest(Self.hdcA),
          "usbTopology": Self.normalA,
        ]))
    assertBound(
      try await exchange(
        "bind.reactivated", request(Self.boardA, 2), expect: nil, handler: handler),
      updated: true, previous: 2, current: 2)
    assertBound(
      try await exchange(
        "bind.reactivatedRetried", request(Self.boardA, 2), expect: nil, handler: handler),
      updated: false, previous: 2, current: 2)

    // Its Loader serial drifts: the binding migrates along its confirmed
    // alias, and the Target's proven alias resolution follows it.
    try write(
      Self.targets, input: "targets-a2-b1-alias.json",
      try Self.targetsDocument(
        [
          targetA2, targetB1,
          Self.target(
            "TGT-ALIAS", identity: digest(Self.aliasKey), revision: 1, connectKey: Self.aliasKey),
        ],
        resolutions: [
          try Self.aliasResolution(
            alias: "TGT-ALIAS", aliasIdentity: digest(Self.aliasKey), canonical: Self.boardA,
            canonicalIdentity: digest(Self.loaderA), canonicalRevision: 2)
        ]))
    usb([driftedLoader], census)
    assertBound(
      try await exchange(
        "bind.loaderDrifted", request(Self.boardA, 2), expect: nil, handler: handler),
      updated: true, previous: 2, current: 3)
    assertBound(
      try await exchange(
        "bind.loaderDriftedRetried", request(Self.boardA, 2), expect: nil, handler: handler),
      updated: false, previous: 2, current: 3)

    // A cross-mode bind refuses what it cannot prove.
    usb([boardALoader], census)
    try write(Self.targets, input: "targets-a1.json", try Self.targetsDocument([targetA1]))
    try write(
      Self.binding, input: "binding-a-installed-without-readback.json",
      try Self.bindingDocument(
        revision: 1, serial: Self.hdcA, topology: Self.normalA,
        evidence: Self.installed(Self.hdcA, readback: false)))
    try await exchange(
      "bind.firstCrossModeWithoutHdcNormalPort", request(Self.boardA, 1), expect: "rejected",
      handler: handler)
    try write(Self.binding, input: "binding-a-installed.json", installedA)
    try write(
      Self.targets, input: "targets-a1-twin.json",
      try Self.targetsDocument([
        targetA1,
        Self.target(
          "TGT-TWIN", identity: digest(Self.hdcA), revision: 1, connectKey: Self.otherKey),
      ]))
    try await exchange(
      "bind.lineageAmbiguous", request(Self.boardA, 1), expect: "rejected", handler: handler)
    // The Loader was adopted as a Target of its own: the binding is replaced
    // before the Target's advance collides with it.
    try write(
      Self.targets, input: "targets-a1-loader-adopted.json",
      try Self.targetsDocument([
        targetA1,
        Self.target(
          "TGT-LOADER", identity: digest(Self.loaderA), revision: 1, connectKey: Self.otherKey),
      ]))
    try await exchange(
      "bind.lineageCollides", request(Self.boardA, 1), expect: "rejected", handler: handler)
    usb([driftedLoader], census)
    try write(
      Self.targets, input: "targets-a2-other-key.json",
      try Self.targetsDocument([
        Self.target(
          Self.boardA, identity: digest(Self.loaderA), revision: 2, connectKey: Self.otherKey)
      ]))
    try await exchange(
      "bind.connectKeyNotAlias", request(Self.boardA, 2), expect: "rejected", handler: handler)
    try write(
      Self.targets, input: "targets-a3-loader.json",
      try Self.targetsDocument([
        Self.target(
          Self.boardA, identity: digest(Self.loaderA), revision: 3, connectKey: Self.hdcA)
      ]))
    try await exchange(
      "bind.migrationNotAdjacent", request(Self.boardA, 3), expect: "rejected", handler: handler)
    usb([boardALoader], census)
    try write(Self.targets, input: "targets-a2.json", try Self.targetsDocument([targetA2]))
    try write(
      Self.binding, input: "binding-a-loader-unattested.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderA, topology: Self.loaderPortA,
        evidence: Self.installed(Self.loaderA)))
    try await exchange(
      "bind.withoutAttestation", request(Self.boardA, 2), expect: "rejected", handler: handler)
    // A serial the new evidence would name is refused before anything is
    // written.
    usb([Self.loader("8711", at: Self.loaderPortA)], census)
    try write(Self.targets, input: "targets-a1.json", try Self.targetsDocument([targetA1]))
    try write(Self.binding, input: "binding-a-installed.json", installedA)
    try await exchange(
      "bind.serialNamedByEvidence", request(Self.boardA, 1), expect: "rejected", handler: handler)
  }
}
