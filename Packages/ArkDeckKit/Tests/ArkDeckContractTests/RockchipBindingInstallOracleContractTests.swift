// Shared Swift oracle for the Rust CLI's `flash install-binding` (CHG-2026-074, TASK-XPA-017,
// milestone M4).

import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Swift `flash install-binding [--rebind]` below its rendering:
/// `RockchipProductBindingBootstrap.installCurrentTarget(rebind:)`, the one
/// call `RockchipDeviceBindingInstallation.installCurrentTarget` makes, over
/// `RockchipProductUSBProbe.singleDAYU200()` and the product binding store of
/// one Application Support root (`<root>/ArkDeck`).
///
/// What a host cannot fix is injected, and nothing else: the identities the
/// probe reads in place of the host's I/O Registry (`systemIdentities`), or
/// the error a registry that cannot be read throws. The CLI's own entry point
/// reads the real I/O Registry and the account's Application Support root, so
/// it is never run here.
///
/// The cases run in order over one root, each after the setup it names (the
/// identities; a file written from `inputs/`, removed, hard-linked or
/// re-moded; a directory or a symbolic link made), and each records its
/// answer — the receipt, or the error as the CLI interpolates it — and then
/// every entry below the root with its kind and mode, a file's size, a link's
/// destination, and every file byte for byte (`steps/`).
///
/// Record a new oracle with
/// `ARKDECK_RUST_BINDING_INSTALL_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class RockchipBindingInstallOracleContractTests: XCTestCase {
  /// The identities the probe reads in place of the host's I/O Registry;
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

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/rockchip-binding-install", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_BINDING_INSTALL_RECORD"
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-binding-install-oracle", directoryHint: .isDirectory)
  /// Serializes every user of the fixed root, Rust replays included.
  private static let lockPath = "/private/tmp/arkdeck-binding-install-oracle.lock"
  /// The Application Support root, as the CLI composes the store below the
  /// account's `Library/Application Support`.
  private static let store = "ArkDeck"
  private static let binding = "ArkDeck/rockchip-binding.json"
  private static let bindingLock = "ArkDeck/.rockchip-binding.lock"

  /// Board A: its HDC serial and port in its normal personality, and its
  /// Loader serial and port. Board B: a second board on the bench.
  private static let hdcA = "150100424a544e4600"
  private static let normalA = "18874368"
  private static let movedA = "19922944"
  private static let loaderA = "loader-serial-0451"
  private static let loaderPortA = "17956864"
  private static let hdcB = "1501ffff0000000000000000000beef1"
  private static let normalB = "20971520"

  private var files: [String: Data] = [:]
  private var steps: [JSONValue] = []
  private var setup: [JSONValue] = []

  private static func digest(_ text: String) -> String {
    SHA256Hex.string(of: Data(text.utf8))
  }

  private static func hdcNormal(
    _ serial: String, at topology: String, name: String? = "\"HDC Device\""
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

  /// A binding as the store writes it: sorted keys and a newline.
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

  /// What the bootstrap installs for `serial` at revision 1.
  private static func installed(_ serial: String) -> [String] {
    [
      "product:e0-iokit-single-dayu200-readback",
      "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
      "identity:serial-sha256=\(digest(serial))",
    ]
  }

  // MARK: - Setup actions, performed here and recorded for the replay

  private func input(_ name: String, _ bytes: Data) -> String {
    let path = "inputs/\(name)"
    if let existing = files[path] {
      precondition(existing == bytes, "\(path) names one input")
    }
    files[path] = bytes
    return path
  }

  private func usb(_ devices: [RockchipProductUSBIdentity]?, _ census: Census) {
    census.set(devices)
    setup.append(
      .object([
        "action": .string("usb"),
        "devices": devices.map { .array($0.map(Self.json)) } ?? .null,
      ]))
  }

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

  private func chmodEntry(_ path: String, _ mode: Int) throws {
    guard chmod(Self.root.appending(path: path).path, mode_t(mode)) == 0 else {
      throw POSIXError(.EPERM)
    }
    setup.append(
      .object([
        "action": .string("chmod"), "path": .string(path),
        "mode": .string(String(mode, radix: 8)),
      ]))
  }

  private func makeDirectory(_ path: String, mode: Int = 0o700) throws {
    let url = Self.root.appending(path: path)
    guard mkdir(url.path, mode_t(mode)) == 0, chmod(url.path, mode_t(mode)) == 0 else {
      throw POSIXError(.EEXIST)
    }
    setup.append(
      .object([
        "action": .string("mkdir"), "path": .string(path),
        "mode": .string(String(mode, radix: 8)),
      ]))
  }

  private func symlinkEntry(_ path: String, to destination: String) throws {
    guard symlink(destination, Self.root.appending(path: path).path) == 0 else {
      throw POSIXError(.EEXIST)
    }
    setup.append(
      .object([
        "action": .string("symlink"), "path": .string(path),
        "destination": .string(destination),
      ]))
  }

  private func hardLink(_ path: String, from existing: String) throws {
    guard
      link(Self.root.appending(path: existing).path, Self.root.appending(path: path).path) == 0
    else { throw POSIXError(.EEXIST) }
    setup.append(
      .object([
        "action": .string("link"), "path": .string(path), "existing": .string(existing),
      ]))
  }

  // MARK: - Steps

  /// Every entry below the root, with its kind and mode, a file's size and a
  /// link's destination, in path order without following a link; each
  /// file's bytes are recorded under `prefix`.
  private func entries(_ prefix: String) throws -> JSONValue {
    var listing: [JSONValue] = []
    func walk(_ relative: String) throws {
      let url = relative.isEmpty ? Self.root : Self.root.appending(path: relative)
      for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
        let path = relative.isEmpty ? name : "\(relative)/\(name)"
        let entry = Self.root.appending(path: path)
        var metadata = stat()
        guard lstat(entry.path, &metadata) == 0 else { throw POSIXError(.EIO) }
        var fields: [String: JSONValue] = [
          "path": .string(path),
          "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
        ]
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
          fields["kind"] = .string("directory")
          listing.append(.object(fields))
          try walk(path)
        case S_IFLNK:
          // A link's own mode is only the creating process's umask.
          fields["mode"] = nil
          fields["kind"] = .string("link")
          fields["destination"] = .string(
            try FileManager.default.destinationOfSymbolicLink(atPath: entry.path))
          listing.append(.object(fields))
        default:
          fields["kind"] = .string("file")
          fields["bytes"] = .integer(Int64(metadata.st_size))
          listing.append(.object(fields))
          files["\(prefix)/\(path)"] = try Data(contentsOf: entry)
        }
      }
    }
    try walk("")
    return .array(listing)
  }

  /// One install, recorded with the setup performed before it and the root
  /// after it; `expect` is the error the CLI interpolates, or nil for a
  /// receipt.
  private func step(
    _ name: String, rebind: Bool = false, expect: String? = nil,
    bootstrap: RockchipProductBindingBootstrap,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let index = steps.count + 1
    let answer: JSONValue
    do {
      let receipt = try bootstrap.installCurrentTarget(rebind: rebind)
      answer = .object([
        "receipt": .object([
          "revision": .integer(Int64(receipt.revision)),
          "usbTopology": .string(receipt.usbTopology),
          "serialDigestSha256": .string(receipt.serialDigestSHA256),
          "created": .bool(receipt.created),
        ])
      ])
      XCTAssertNil(expect, "\(name) was answered: \(answer)", file: file, line: line)
    } catch {
      answer = .object(["error": .string("\(error)")])
      XCTAssertEqual(expect, "\(error)", name, file: file, line: line)
    }
    steps.append(
      .object([
        "index": .integer(Int64(index)), "name": .string(name), "rebind": .bool(rebind),
        "setup": .array(setup), "answer": answer,
        "entries": try entries(String(format: "steps/%02d-%@", index, name)),
      ]))
    setup = []
  }

  // MARK: - The oracle

  func testSwiftInstallsTheBindingTheRustCLIReplays() throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EACCES) }
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }

    let census = Census()
    let probe = RockchipProductUSBProbe(identitySource: census.read)
    let bootstrap = RockchipProductBindingBootstrap(
      probe: { try probe.singleDAYU200() },
      store: RockchipProductBindingStore(
        rootURL: Self.root.appending(path: Self.store, directoryHint: .isDirectory)))

    try probeRefusals(census, bootstrap)
    try installs(census, bootstrap)
    try storeRefusals(census, bootstrap)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["steps": .array(steps)])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "RockchipBindingInstallOracleContractTests.testSwiftInstallsTheBindingTheRustCLIReplays"
          ),
          "root": .string(Self.root.path),
          "applicationSupportRoot": .string(Self.root.appending(path: Self.store).path),
          "owners": .array([
            .string("RockchipProductBindingBootstrap.installCurrentTarget"),
            .string("RockchipProductUSBProbe.singleDAYU200"),
            .string("RockchipProductBindingStore.install"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  // MARK: The probe refuses; nothing below the root is touched

  private func probeRefusals(
    _ census: Census, _ bootstrap: RockchipProductBindingBootstrap
  ) throws {
    usb(nil, census)
    try step(
      "registryUnavailable",
      expect: "admissionRejected(\"USB registry unavailable\")", bootstrap: bootstrap)
    usb([], census)
    try step(
      "noDevice", expect: "admissionRejected(\"DAYU200 target unavailable\")",
      bootstrap: bootstrap)
    // Another vendor's device, and a RockUSB normal-mode product that does
    // not name itself an HDC device.
    usb(
      [
        RockchipProductUSBIdentity(
          serial: "keyboard-serial", vendorID: 0x05ac, productID: 0x0250, topology: "1048576",
          productName: "\"Keyboard\""),
        Self.hdcNormal(Self.hdcB, at: Self.normalB, name: "\"Other Device\""),
        Self.hdcNormal(Self.hdcB, at: Self.normalB, name: nil),
      ], census)
    try step(
      "unregisteredOnly", expect: "admissionRejected(\"DAYU200 target unavailable\")",
      bootstrap: bootstrap)
    usb([Self.hdcNormal(Self.hdcA, at: Self.normalA), Self.loader(Self.loaderA, at: "1")], census)
    try step(
      "twoBoards", expect: "admissionRejected(\"DAYU200 target ambiguous\")",
      bootstrap: bootstrap)
    let notRegistered =
      "admissionRejected(\"the single USB identity is not a registered DAYU200 mode\")"
    usb([Self.hdcNormal(Self.hdcA, at: "")], census)
    try step("emptyTopology", expect: notRegistered, bootstrap: bootstrap)
    usb([Self.hdcNormal(Self.hdcA, at: "0x1200000")], census)
    try step("nonDecimalTopology", expect: notRegistered, bootstrap: bootstrap)
    usb([Self.loader("", at: Self.loaderPortA)], census)
    try step("emptySerial", expect: notRegistered, bootstrap: bootstrap)
  }

  // MARK: Installs, repeats and rebinds

  private func installs(_ census: Census, _ bootstrap: RockchipProductBindingBootstrap) throws {
    let differs =
      "productionConfigurationUnavailable(\"durable binding differs from the only connected "
      + "Loader; explicit rebind is required\")"
    // The first install creates the root, its lock and the binding; the
    // quoted product name is how the I/O Registry spells it.
    usb([Self.hdcNormal(Self.hdcA, at: Self.normalA)], census)
    try step("install", bootstrap: bootstrap)
    try step("installAgain", bootstrap: bootstrap)
    // A product name without the quotes is the same HDC device.
    usb([Self.hdcNormal(Self.hdcA, at: Self.normalA, name: "HDC Device")], census)
    try step("installAgainUnquotedName", bootstrap: bootstrap)
    // The same board in its Loader personality, the same board on another
    // port, and another board: each is refused without `--rebind`.
    usb([Self.loader(Self.loaderA, at: Self.loaderPortA)], census)
    try step("loaderWithoutRebind", expect: differs, bootstrap: bootstrap)
    usb([Self.hdcNormal(Self.hdcA, at: Self.movedA)], census)
    try step("portMovedWithoutRebind", expect: differs, bootstrap: bootstrap)
    usb([Self.hdcNormal(Self.hdcB, at: Self.normalB)], census)
    try step("otherBoardWithoutRebind", expect: differs, bootstrap: bootstrap)
    // `--rebind` continues the lineage: the next revision, with what it
    // replaced and the operator's selection.
    usb([Self.loader(Self.loaderA, at: Self.loaderPortA)], census)
    try step("rebindToLoader", rebind: true, bootstrap: bootstrap)
    try step("rebindSameAgain", rebind: true, bootstrap: bootstrap)
    try step("installSameWithoutRebind", bootstrap: bootstrap)
    usb([Self.hdcNormal(Self.hdcA, at: Self.movedA)], census)
    try step("rebindToMovedPort", rebind: true, bootstrap: bootstrap)
    // A rebind with nothing installed installs revision 1.
    try remove(Self.binding)
    usb([Self.hdcNormal(Self.hdcB, at: Self.normalB)], census)
    try step("rebindWithNothingInstalled", rebind: true, bootstrap: bootstrap)
    // The root is made owner-only again before anything is read.
    try chmodEntry(Self.store, 0o755)
    try step("rootModeRepaired", bootstrap: bootstrap)
    // Nothing installed, the lock gone: a first install makes both.
    try remove(Self.binding)
    try remove(Self.bindingLock)
    usb([Self.hdcNormal(Self.hdcA, at: Self.normalA)], census)
    try step("installAfterLockRemoved", bootstrap: bootstrap)
  }

  // MARK: The store refuses what it cannot own

  private func storeRefusals(
    _ census: Census, _ bootstrap: RockchipProductBindingBootstrap
  ) throws {
    let unavailable: (String) -> String = {
      "productionConfigurationUnavailable(\"\($0)\")"
    }
    usb([Self.hdcNormal(Self.hdcA, at: Self.normalA)], census)
    let valid = try Self.bindingDocument(
      revision: 1, serial: Self.hdcA, topology: Self.normalA, evidence: Self.installed(Self.hdcA))

    try chmodEntry(Self.binding, 0o644)
    try step(
      "bindingNotOwnerOnly",
      expect: unavailable("durable binding must be an owner-only regular file"),
      bootstrap: bootstrap)
    try hardLink("ArkDeck/binding-second-name", from: Self.binding)
    try chmodEntry(Self.binding, 0o600)
    try step(
      "bindingHardLinked",
      expect: unavailable("durable binding must be an owner-only regular file"),
      bootstrap: bootstrap)
    try remove("ArkDeck/binding-second-name")
    try write(Self.binding, input: "empty", Data())
    try step(
      "bindingEmpty", expect: unavailable("durable binding size is invalid"),
      bootstrap: bootstrap)
    try write(
      Self.binding, input: "oversized",
      Data(repeating: 0x20, count: 64 * 1_024) + Data([0x0A]))
    try step(
      "bindingOversized", expect: unavailable("durable binding size is invalid"),
      bootstrap: bootstrap)
    // A document that is not JSON at all escapes the store as Foundation's
    // own parse error, whose words are the host's; it is not recorded.
    try write(Self.binding, input: "not-an-object", Data("[]\n".utf8))
    try step(
      "bindingNotAnObject", expect: unavailable("durable binding schema is invalid"),
      bootstrap: bootstrap)
    try write(
      Self.binding, input: "extra-key",
      Data(
        "{\"evidence\":[\"a\"],\"extra\":1,\"revision\":1,\"serial\":\"s\",\"usbTopology\":\"1\"}\n"
          .utf8))
    try step(
      "bindingExtraKey", expect: unavailable("durable binding schema is invalid"),
      bootstrap: bootstrap)
    try write(
      Self.binding, input: "wrong-types",
      Data(
        "{\"evidence\":\"a\",\"revision\":1,\"serial\":\"s\",\"usbTopology\":\"1\"}\n".utf8))
    try step(
      "bindingWrongTypes", expect: unavailable("durable binding cannot be decoded"),
      bootstrap: bootstrap)
    try write(
      Self.binding, input: "serial-in-evidence",
      try Self.bindingDocument(
        revision: 1, serial: Self.hdcA, topology: Self.normalA,
        evidence: Self.installed(Self.hdcA) + ["leaked:\(Self.hdcA)"]))
    try step(
      "bindingSerialInEvidence", expect: unavailable("durable binding snapshot is invalid"),
      bootstrap: bootstrap)
    try write(
      Self.binding, input: "revision-zero",
      try Self.bindingDocument(
        revision: 0, serial: Self.hdcA, topology: Self.normalA,
        evidence: Self.installed(Self.hdcA)))
    try step(
      "bindingRevisionZero", expect: unavailable("durable binding snapshot is invalid"),
      bootstrap: bootstrap)
    try remove(Self.binding)
    try makeDirectory(Self.binding)
    try step(
      "bindingIsDirectory",
      expect: unavailable("durable binding must be an owner-only regular file"),
      bootstrap: bootstrap)
    try remove(Self.binding)
    try write("ArkDeck/elsewhere.json", input: "valid", valid)
    try symlinkEntry(Self.binding, to: "elsewhere.json")
    try step(
      "bindingSymbolicLink", expect: unavailable("durable binding cannot be opened"),
      bootstrap: bootstrap)
    try remove(Self.binding)
    try remove("ArkDeck/elsewhere.json")
    try write(Self.binding, input: "valid", valid)

    try chmodEntry(Self.bindingLock, 0o644)
    try step(
      "lockNotOwnerOnly",
      expect: unavailable("binding lock must be an owner-only regular file"),
      bootstrap: bootstrap)
    try remove(Self.bindingLock)
    try write("ArkDeck/elsewhere.lock", input: "empty", Data())
    try symlinkEntry(Self.bindingLock, to: "elsewhere.lock")
    try step(
      "lockSymbolicLink", expect: unavailable("binding lock cannot be opened"),
      bootstrap: bootstrap)
    try remove(Self.bindingLock)
    try remove("ArkDeck/elsewhere.lock")

    try makeDirectory("moved")
    try write("moved/rockchip-binding.json", input: "valid", valid)
    try remove(Self.binding)
    try remove(Self.store)
    try symlinkEntry(Self.store, to: "moved")
    try step(
      "rootSymbolicLink", expect: unavailable("binding root cannot be a symbolic link"),
      bootstrap: bootstrap)
    try remove(Self.store)
    try remove("moved")
    // The root is made again, as the first install made it.
    try step("installWithRootRemoved", bootstrap: bootstrap)
  }
}
