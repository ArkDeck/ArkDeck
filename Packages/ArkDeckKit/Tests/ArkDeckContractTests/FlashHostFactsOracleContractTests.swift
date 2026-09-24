// Shared Swift oracle for the Rust Flash host facts (CHG-2026-074, TASK-XPA-017, milestone M4).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `flash.bootloader-status` and `flash.prerequisites` through the
/// daemon's control-plane handler, composed with the owners the daemon
/// composes for them: `ProductRockchipBootloaderStatusObserver` over the
/// Target store, the Rockchip binding store and the post-flash HDC binding
/// store of the Application Support root, and `TargetStoreRockchipRuntimeFactsPort`
/// over the same three with the measured native RockUSB identity and the live
/// mode probe.
///
/// What a host cannot fix is injected, and nothing else: the USB census both
/// read in place of the I/O Registry; which `arkforged` the RockUSB identity
/// measures (none, a relative path, a changed digest, the fixture's own); the
/// Loader observation the probe asks ArkForge for; and the HDC it reads, the
/// shared fake (`HDCOracleFake`), whose answers are recorded beside it. The
/// probe runs its children in a product-owned directory under this user's
/// caches, which no answer names. A second facts port without a probe stands
/// for a daemon composed without HDC. No device, ArkForge daemon or daemon
/// process.
///
/// Every exchange runs in order over one root, after the setup it names (a
/// file written from `inputs/` or removed, the census, the identity, the
/// Loader observation, the probe, the fake's mode), and records the HDC calls
/// it made. Requests are ones a caller may send under the published request
/// schemas: parameters the handler ignores or refuses by name are the Rust
/// replay's own.
///
/// Record a new oracle with
/// `ARKDECK_RUST_FLASH_HOST_FACTS_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class FlashHostFactsOracleContractTests: XCTestCase {
  private final class Census: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [RockchipProductUSBIdentity]? = []

    func set(_ devices: [RockchipProductUSBIdentity]?) { lock.withLock { self.devices = devices } }

    func read() throws -> [RockchipProductUSBIdentity] {
      guard let devices = lock.withLock({ devices }) else {
        throw RockchipFlashExecutionError.admissionRejected("USB registry unavailable")
      }
      return devices
    }
  }

  /// The configured `arkforged`, as the daemon's resolver reads it.
  private final class Identity: RuntimeExecutableResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var daemonPath: String?
    private var declaredSHA256: String?

    func set(daemonPath: String?, declaredSHA256: String?) {
      lock.withLock {
        self.daemonPath = daemonPath
        self.declaredSHA256 = declaredSHA256
      }
    }

    func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
      let (path, declared) = lock.withLock { (daemonPath, declaredSHA256) }
      return try ArkForgeNativeRockUSBExecutableResolver(
        daemonPath: path, declaredSHA256: declared
      ).resolveExecutable(providerID: providerID)
    }
  }

  /// ArkForge's dual-source Loader observation, scripted.
  private final class Loader: ArkForgeLoaderObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var topology: String?
    private var refusal = "DAYU200 target unavailable"

    func observe(topology: String) { lock.withLock { self.topology = topology } }
    func refuse(_ reason: String) {
      lock.withLock {
        topology = nil
        refusal = reason
      }
    }

    func observeLoader(
      stableIdentitySHA256: String, expectedUSBTopology: String?, requestID: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      let (topology, refusal) = lock.withLock { (self.topology, self.refusal) }
      guard let topology else {
        throw RockchipFlashExecutionError.admissionRejected(refusal)
      }
      return RockchipRuntimeLoaderIdentity(
        serialDigestSHA256: stableIdentitySHA256, topology: topology)
    }
  }

  /// The daemon's prerequisite observer with its probe, or without one.
  private final class Prerequisites: RockchipFlashPrerequisiteObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let probed: TargetStoreRockchipRuntimeFactsPort
    private let unprobed: TargetStoreRockchipRuntimeFactsPort
    private var probe = true

    init(probed: TargetStoreRockchipRuntimeFactsPort, unprobed: TargetStoreRockchipRuntimeFactsPort) {
      self.probed = probed
      self.unprobed = unprobed
    }

    func set(probe: Bool) { lock.withLock { self.probe = probe } }

    func observePrerequisites(targetID: String) async throws -> [RockchipPrerequisiteObservation] {
      let port = lock.withLock { probe ? probed : unprobed }
      return try await port.observePrerequisites(targetID: targetID)
    }
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/flash-host-facts", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_FLASH_HOST_FACTS_RECORD"
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-flash-host-facts-oracle", directoryHint: .isDirectory)
  private static let state = root.appending(path: "state", directoryHint: .isDirectory)
  private static let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Caches/com.arkdeck.ArkDeck", directoryHint: .isDirectory)
    .appending(path: "flash-host-facts-oracle", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-25T00:00:00Z"
  private static let targets = "state/targets/targets.json"
  private static let binding = "rockchip-binding.json"
  private static let alias = "rockchip-post-flash-hdc-binding.json"

  private static let targetID = "TGT-HOST"
  /// The board's Loader serial, its HDC serial before and after the flash,
  /// and another board's.
  private static let loaderSerial = "loader-serial-0451"
  private static let hdcKey = "1501ffff00000000000000000000cafe"
  private static let newKey = "1501ffff0000000000000000000beef1"
  private static let otherKey = "1501ffff000000000000000000000003"
  private static let loaderTopology = "17956864"
  private static let normalTopology = "18874368"
  private static let arkforged = Data("#!/bin/sh\n# arkforged stand-in; never run.\nexit 0\n".utf8)

  /// The fake's answers: the target list in each mode, and the build.
  private static let answers = #"""
    # flash.prerequisites answers of the shared fake HDC, by mode.
    hdc_key=1501ffff00000000000000000000cafe
    new_key=1501ffff0000000000000000000beef1
    case "$*" in
    "list targets -v")
      case "$mode" in
      hdcKey) printf '%s\t\tUSB\tConnected\tlocalhost\n' "$hdc_key" ;;
      newKey) printf '%s\t\tUSB\tConnected\tlocalhost\n' "$new_key" ;;
      offline) printf '%s\t\tUSB\tOffline\tlocalhost\n' "$hdc_key" ;;
      empty) printf '[Empty]\r\n' ;;
      malformed) printf 'no device table here\n' ;;
      *) printf 'list targets failed\n' >&2; exit 1 ;;
      esac ;;
    "-t $hdc_key shell param get const.ohos.fullname"|"-t $new_key shell param get const.ohos.fullname")
      printf 'OpenHarmony-7.0.0.36\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  private var files: [String: Data] = [:]
  private var exchanges: [JSONValue] = []
  private var setup: [JSONValue] = []

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

  private static func record(
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

  private static func targetsDocument(_ records: [JSONValue]) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object(["schemaVersion": .string("1.0.0"), "targets": .array(records)]))
  }

  /// The Loader-bound Target at revision 2, whose adoption connect key is
  /// its HDC serial before the flash.
  private static let hostTarget = record(
    targetID, identity: digest(loaderSerial), revision: 2, connectKey: hdcKey)

  private static func bindingDocument(
    revision: Int, serial: String, topology: String, evidence: [String]
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      RockchipProductBindingSnapshot(
        revision: revision, serial: serial, usbTopology: topology, evidence: evidence))
  }

  /// The complete adjacent lineage of a Loader rebind: revision 2 names the
  /// Loader, its previous HDC-normal identity and topology, the Runtime's
  /// selection, and that identity as its one confirmed HDC-normal alias.
  private static let loaderLineage = [
    "product:e0-iokit-single-loader-readback",
    "identity:serial-sha256=\(digest(loaderSerial))",
    "identity:previous-serial-sha256=\(digest(hdcKey))",
    "binding:previous-revision=1",
    "binding:previous-usb-topology=\(normalTopology)",
    "rebind:user-selection-sha256=\(String(repeating: "e", count: 64))",
    "identity:hdc-normal-alias-sha256=\(digest(hdcKey))",
    "binding:hdc-normal-alias-usb-topology=\(normalTopology)",
  ]

  private static func aliasDocument(
    targetID: String = targetID, revision: Int, loader: String = digest(loaderSerial),
    key: String = newKey, topology: String = normalTopology
  ) throws -> Data {
    let record = RockchipPostFlashHDCBinding(
      targetID: targetID, bindingRevision: revision,
      stableLoaderIdentitySHA256: loader,
      previousHDCIdentitySHA256: digest(hdcKey),
      hdcIdentitySHA256: digest(key), hdcConnectKey: key,
      usbTopology: topology, productModel: "ohos", buildVersion: "OpenHarmony-7.0.0.36",
      jobID: "job-flash-host", establishedAtUTC: "2026-09-20T00:00:00Z")
    return try CanonicalJSONEncoders.canonical().encode(record) + Data([0x0A])
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

  private func usb(_ devices: [RockchipProductUSBIdentity]?, _ census: Census) {
    census.set(devices)
    setup.append(
      .object([
        "action": .string("usb"),
        "devices": devices.map { .array($0.map(Self.json)) } ?? .null,
      ]))
  }

  /// `daemon` is relative to the root when `underRoot`, else sent as it is.
  private func rockusb(
    _ identity: Identity, daemon: String?, underRoot: Bool = true, declared: String?
  ) {
    identity.set(
      daemonPath: daemon.map { underRoot ? Self.root.appending(path: $0).path : $0 },
      declaredSHA256: declared)
    setup.append(
      .object([
        "action": .string("rockusb"),
        "daemon": daemon.map(JSONValue.string) ?? .null,
        "underRoot": .bool(underRoot),
        "declared": declared.map(JSONValue.string) ?? .null,
      ]))
  }

  private func loaderObservation(_ loader: Loader, topology: String?, refusal: String? = nil) {
    if let topology {
      loader.observe(topology: topology)
    } else {
      loader.refuse(refusal ?? "DAYU200 target unavailable")
    }
    setup.append(
      .object([
        "action": .string("loader"),
        "topology": topology.map(JSONValue.string) ?? .null,
        "refusal": topology == nil ? .string(refusal ?? "DAYU200 target unavailable") : .null,
      ]))
  }

  private func probe(_ prerequisites: Prerequisites, _ probe: Bool) {
    prerequisites.set(probe: probe)
    setup.append(.object(["action": .string("probe"), "probe": .bool(probe)]))
  }

  private func hdcMode(_ mode: String) throws {
    try HDCOracleFake.setMode(mode)
    setup.append(.object(["action": .string("hdcMode"), "mode": .string(mode)]))
  }

  // MARK: - Exchanges

  /// The fake's calls since the last exchange, each its arguments.
  private func hdcCalls() throws -> JSONValue {
    let log = String(decoding: try HDCOracleFake.invocations(), as: UTF8.self)
    try Data().write(to: HDCOracleFake.root.appending(path: "hdc-invocations.log"))
    return .array(
      log.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        .array(
          line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            .dropLast().map { .string(String($0)) })
      })
  }

  @discardableResult
  private func exchange(
    _ name: String, _ method: String, _ params: [String: JSONValue],
    expect: String?, handler: RuntimeControlPlaneHandler,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws -> JSONValue {
    let index = exchanges.count + 1
    let answer = try await HDCOracleHarness.send(
      handler, method, params, frameID: "flash-host-facts-\(index)")
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
        "index": .integer(Int64(index)), "name": .string(name), "method": .string(method),
        "params": .object(params), "setup": .array(setup), "answer": answer,
        "hdcCalls": try hdcCalls(),
      ]))
    setup = []
    return answer
  }

  private func assertStatuses(
    _ answer: JSONValue, _ expected: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .object(let fields) = answer, case .object(let result)? = fields["result"],
      case .array(let observations)? = result["observations"]
    else { return XCTFail("no observations: \(answer)", file: file, line: line) }
    let statuses = observations.compactMap { observation -> String? in
      guard case .object(let item) = observation, case .string(let status)? = item["status"]
      else { return nil }
      return status
    }
    XCTAssertEqual(statuses, expected, file: file, line: line)
  }

  // MARK: - The oracle

  func testSwiftAnswersTheFlashHostFactsTheRustDaemonReplays() async throws {
    let hdcLock = try HDCOracleFake.lock()
    defer { close(hdcLock) }
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }
    try? manager.removeItem(at: Self.workingDirectory)
    try manager.createDirectory(
      at: Self.workingDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.workingDirectory) }
    let hdc = try HDCOracleFake.install(answers: Self.answers)

    let census = Census()
    let identity = Identity()
    let loader = Loader()
    let targetStore = try RuntimeTargetStore(
      directoryURL: Self.state.appending(path: "targets", directoryHint: .isDirectory))
    let bindingStore = RockchipProductBindingStore(rootURL: Self.root)
    let postFlash = RockchipPostFlashHDCBindingStore(rootURL: Self.root)
    let prober = FoundationRockchipLiveModeProbe(
      hdcResolver: try FixedExecutableResolver.hashing(path: hdc.path, providerID: "hdc"),
      runner: FoundationRockchipRuntimeCommandRunner(workingDirectory: Self.workingDirectory),
      loaderObserver: loader)
    func port(_ prober: (any RockchipLiveModeProbing)?) -> TargetStoreRockchipRuntimeFactsPort {
      TargetStoreRockchipRuntimeFactsPort(
        targetStore: targetStore, resolver: identity, prober: prober,
        bindingStore: bindingStore, postFlashHDCBindingStore: postFlash,
        nowUTC: { Self.nowUTC })
    }
    let prerequisites = Prerequisites(probed: port(prober), unprobed: port(nil))
    let observer = ProductRockchipBootloaderStatusObserver(
      targetStore: targetStore, bindingStore: bindingStore, postFlashHDCBindingStore: postFlash,
      usbProbe: RockchipProductUSBProbe(identitySource: { try census.read() }))
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
      flashPrerequisiteObserver: prerequisites,
      rockchipBootloaderStatusObserver: observer)

    try write("arkforged", input: "arkforged", Self.arkforged, mode: 0o700)
    try await bootloaderStatus(handler: handler, census: census)
    try await prerequisiteFacts(
      handler: handler, identity: identity, loader: loader, prerequisites: prerequisites)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["exchanges": .array(exchanges)])) + Data("\n".utf8)
    files["hdc"] = HDCOracleFake.driver
    files["hdc-answers.sh"] = Data(Self.answers.utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("FlashHostFactsOracleContractTests"),
          "applicationSupportRoot": .string(Self.root.path),
          "stateDirectory": .string(Self.state.path),
          "hdcRoot": .string(HDCOracleFake.root.path),
          "nowUTC": .string(Self.nowUTC),
          "owners": .array([
            .string("ProductRockchipBootloaderStatusObserver"),
            .string("TargetStoreRockchipRuntimeFactsPort"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  // MARK: flash.bootloader-status

  private func bootloaderStatus(handler: RuntimeControlPlaneHandler, census: Census) async throws {
    let status = "flash.bootloader-status"
    let boardLoader = Self.loader(Self.loaderSerial, at: Self.loaderTopology)
    let flashed = Self.hdcNormal(Self.newKey, at: Self.normalTopology)
    let unrelated = RockchipProductUSBIdentity(
      serial: "unrelated-serial", vendorID: 0x05ac, productID: 0x12a8, topology: "99",
      productName: "iPhone")

    try await exchange("status.absent", status, [:], expect: nil, handler: handler)
    usb([unrelated], census)
    try await exchange("status.unrelatedOnly", status, [:], expect: nil, handler: handler)
    usb([boardLoader, Self.hdcNormal(Self.otherKey, at: "19791872")], census)
    try await exchange("status.twoBoards", status, [:], expect: nil, handler: handler)
    usb(nil, census)
    try await exchange("status.registryUnavailable", status, [:], expect: "rejected", handler: handler)
    usb([boardLoader], census)
    try await exchange("status.loaderUnbound", status, [:], expect: nil, handler: handler)
    usb([Self.hdcNormal(Self.hdcKey, at: Self.normalTopology, named: " HDC Device ")], census)
    try await exchange("status.hdcNormalUnbound", status, [:], expect: nil, handler: handler)
    usb([boardLoader], census)
    try write(Self.targets, input: "targets-host.json", try Self.targetsDocument([Self.hostTarget]))
    try await exchange("status.targetBindingUnprepared", status, [:], expect: nil, handler: handler)
    try write(
      Self.binding, input: "binding-loader-lineage.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage))
    try await exchange("status.exactBoundLoader", status, [:], expect: nil, handler: handler)
    usb([Self.loader(Self.loaderSerial, at: "20000000")], census)
    try await exchange("status.loaderAtAnotherPort", status, [:], expect: nil, handler: handler)
    usb([boardLoader], census)
    try write(
      Self.targets, input: "targets-host-twice.json",
      try Self.targetsDocument([
        Self.hostTarget,
        Self.record(
          "TGT-TWIN", identity: Self.digest(Self.loaderSerial), revision: 1,
          connectKey: Self.otherKey),
      ]))
    try await exchange("status.twoTargets", status, [:], expect: nil, handler: handler)
    try write(Self.targets, input: "targets-host.json", try Self.targetsDocument([Self.hostTarget]))
    try write(
      Self.binding, input: "binding-lineage-without-previous.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage.filter { !$0.hasPrefix("binding:previous-revision=") }))
    try await exchange("status.lineageInvalid", status, [:], expect: nil, handler: handler)
    try write(
      Self.binding, input: "binding-loader-lineage.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage))
    usb([flashed], census)
    try write(Self.alias, input: "alias-revision-2.json", try Self.aliasDocument(revision: 2))
    try await exchange("status.exactBoundAlias", status, [:], expect: nil, handler: handler)
    try write(
      Self.targets, input: "targets-host-and-alias-owner.json",
      try Self.targetsDocument([
        Self.hostTarget,
        Self.record(
          "TGT-OWNER", identity: Self.digest(Self.newKey), revision: 1,
          connectKey: Self.otherKey),
      ]))
    try await exchange("status.aliasOwnedElsewhere", status, [:], expect: nil, handler: handler)
    try write(Self.targets, input: "targets-host.json", try Self.targetsDocument([Self.hostTarget]))
    try write(
      Self.binding, input: "binding-lineage-without-previous.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage.filter { !$0.hasPrefix("binding:previous-revision=") }))
    try await exchange("status.aliasRouteLineageInvalid", status, [:], expect: "rejected", handler: handler)
    try write(
      Self.binding, input: "binding-loader-lineage.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage), mode: 0o644)
    try await exchange("status.bindingSharedMode", status, [:], expect: "rejected", handler: handler)
    try remove(Self.binding)
    try remove(Self.alias)
    try remove(Self.targets)
  }

  // MARK: flash.prerequisites

  private func prerequisiteFacts(
    handler: RuntimeControlPlaneHandler, identity: Identity, loader: Loader,
    prerequisites: Prerequisites
  ) async throws {
    let method = "flash.prerequisites"
    let request: [String: JSONValue] = [
      "targetId": .string(Self.targetID), "profileReference": .string("dayu200"),
    ]
    let satisfied = ["satisfied", "satisfied", "satisfied", "unknown"]
    let unprepared = ["unknown", "unsatisfied", "unknown", "unknown"]
    let unknown = ["unknown", "unknown", "unknown", "unknown"]
    let sha = Self.digest(String(decoding: Self.arkforged, as: UTF8.self))

    try await exchange("prerequisites.noParameters", method, [:], expect: "invalidParams", handler: handler)
    try await exchange(
      "prerequisites.unsupportedProfile", method,
      ["targetId": .string(Self.targetID), "profileReference": .string("dayu600")],
      expect: "invalidParams", handler: handler)
    try await exchange("prerequisites.notAdopted", method, request, expect: "notFound", handler: handler)
    try write(Self.targets, input: "targets-host.json", try Self.targetsDocument([Self.hostTarget]))
    try await exchange("prerequisites.laneNotConfigured", method, request, expect: "rejected", handler: handler)
    rockusb(identity, daemon: "arkforged", underRoot: false, declared: sha)
    try await exchange("prerequisites.relativeDaemon", method, request, expect: "rejected", handler: handler)
    rockusb(identity, daemon: "arkforged", declared: String(repeating: "0", count: 64))
    try await exchange("prerequisites.digestChanged", method, request, expect: "rejected", handler: handler)
    rockusb(identity, daemon: "arkforged", declared: sha)
    probe(prerequisites, false)
    assertStatuses(
      try await exchange("prerequisites.unprobed", method, request, expect: nil, handler: handler),
      unknown)
    probe(prerequisites, true)
    try hdcMode("hdcKey")
    assertStatuses(
      try await exchange("prerequisites.hdcUnprepared", method, request, expect: nil, handler: handler),
      unprepared)
    try write(
      Self.binding, input: "binding-loader-lineage.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage))
    assertStatuses(
      try await exchange("prerequisites.hdcReady", method, request, expect: nil, handler: handler),
      satisfied)
    try hdcMode("offline")
    loaderObservation(loader, topology: Self.loaderTopology)
    assertStatuses(
      try await exchange("prerequisites.loaderReady", method, request, expect: nil, handler: handler),
      satisfied)
    try hdcMode("empty")
    loaderObservation(loader, topology: nil, refusal: "DAYU200 target unavailable")
    assertStatuses(
      try await exchange("prerequisites.absent", method, request, expect: nil, handler: handler),
      unknown)
    try hdcMode("malformed")
    assertStatuses(
      try await exchange("prerequisites.listMalformed", method, request, expect: nil, handler: handler),
      unknown)
    try hdcMode("failing")
    assertStatuses(
      try await exchange("prerequisites.listFailing", method, request, expect: nil, handler: handler),
      unknown)
    try hdcMode("empty")
    loaderObservation(loader, topology: Self.loaderTopology)
    try remove(Self.binding)
    assertStatuses(
      try await exchange("prerequisites.loaderUnprepared", method, request, expect: nil, handler: handler),
      unprepared)
    try write(
      Self.binding, input: "binding-loader-lineage.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage), mode: 0o644)
    try await exchange("prerequisites.bindingSharedMode", method, request, expect: "rejected", handler: handler)
    try write(
      Self.binding, input: "binding-extra-key.json",
      Data(
        #"{"evidence":["product:e0-iokit-single-loader-readback"],"extra":true,"revision":2,"serial":"loader-serial-0451","usbTopology":"17956864"}"#
          .utf8))
    try await exchange("prerequisites.bindingSchema", method, request, expect: "rejected", handler: handler)
    try write(
      Self.binding, input: "binding-evidence-names-serial.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage + ["note:\(Self.loaderSerial)"]))
    try await exchange("prerequisites.bindingSnapshot", method, request, expect: "rejected", handler: handler)
    try write(
      Self.binding, input: "binding-lineage-without-previous.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage.filter { !$0.hasPrefix("binding:previous-revision=") }))
    try await exchange("prerequisites.lineageInvalid", method, request, expect: "rejected", handler: handler)
    try write(
      Self.binding, input: "binding-loader-lineage.json",
      try Self.bindingDocument(
        revision: 2, serial: Self.loaderSerial, topology: Self.loaderTopology,
        evidence: Self.loaderLineage))
    try hdcMode("newKey")
    try write(
      Self.alias, input: "alias-other-target.json",
      try Self.aliasDocument(targetID: "TGT-ELSE", revision: 2))
    try await exchange("prerequisites.aliasOfAnotherTarget", method, request, expect: "rejected", handler: handler)
    try write(Self.alias, input: "alias-revision-4.json", try Self.aliasDocument(revision: 4))
    try await exchange("prerequisites.aliasReissued", method, request, expect: "rejected", handler: handler)
    try write(
      Self.alias, input: "alias-revision-4-other-loader.json",
      try Self.aliasDocument(revision: 4, loader: String(repeating: "b", count: 64)))
    try await exchange("prerequisites.aliasNewer", method, request, expect: "rejected", handler: handler)
    try write(
      Self.alias, input: "alias-revision-2-other-loader.json",
      try Self.aliasDocument(revision: 2, loader: String(repeating: "b", count: 64)))
    try await exchange("prerequisites.aliasOtherLoader", method, request, expect: "rejected", handler: handler)
    try write(Self.alias, input: "alias-revision-2.json", try Self.aliasDocument(revision: 2))
    try write(
      Self.targets, input: "targets-host-and-alias-owner.json",
      try Self.targetsDocument([
        Self.hostTarget,
        Self.record(
          "TGT-OWNER", identity: Self.digest(Self.newKey), revision: 1,
          connectKey: Self.otherKey),
      ]))
    try await exchange("prerequisites.aliasOwnedElsewhere", method, request, expect: "rejected", handler: handler)
    try write(Self.targets, input: "targets-host.json", try Self.targetsDocument([Self.hostTarget]))
    assertStatuses(
      try await exchange("prerequisites.aliasRouted", method, request, expect: nil, handler: handler),
      satisfied)
    // An older alias is not this revision's route: the adoption key is.
    try hdcMode("hdcKey")
    try write(Self.alias, input: "alias-revision-1.json", try Self.aliasDocument(revision: 1))
    assertStatuses(
      try await exchange("prerequisites.aliasOlder", method, request, expect: nil, handler: handler),
      satisfied)
    try remove(Self.alias)
    try remove(Self.binding)
    try remove(Self.targets)
  }
}
