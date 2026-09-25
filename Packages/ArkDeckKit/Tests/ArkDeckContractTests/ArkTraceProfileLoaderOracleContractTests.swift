// Shared Swift oracle for the Rust ArkTrace distribution profile loader
// (CHG-2026-074, TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Swift `ArkTraceSummaryAnalyzerProfileLoader.loadProfiles(descriptorURL:)`,
/// the loader the daemon runs for `ARKDECK_ARKTRACE_DESCRIPTOR`, over
/// distributions built at one fixed physical root, the oracle
/// `rust/tests/fixtures/arktrace-profile-loader` the Rust loader replays.
///
/// Each case has its own directory: an ArkTrace CLI distribution laid out as
/// the manifest names it, and the reviewed descriptor that selects it. The
/// distribution's executables are inert text (the loader never runs them; the
/// doctor here is a stub), and every byte is fixed, so every digest is. The
/// cases cover a loaded pair of profiles — with the tree evidence a trust
/// checker returns, and in a private snapshot generation, first made and then
/// reused — and every refusal the loader has, by the reason the daemon
/// composes from it (`main.swift`: a loader error's own reason, and
/// `analyzer.arktraceDescriptorInvalid` for any other error): a missing,
/// writable or malformed descriptor (JSON the strict validator refuses,
/// another shape, key set, format version or root, a digest that is not one,
/// a duplicate member, too many bytes), a root that is missing, a link or
/// writable, a manifest that is missing, drifted, duplicated, closed over
/// other keys, of another contract, of another type, or naming a path out of
/// its root; a tool, parser, parser manifest, signing record or receipt that
/// drifted; a trust checker that refuses or replaces the root; a doctor that
/// fails; a link in the layout; a writable ancestor or tree entry; and the
/// snapshot generation's refusals (a linked snapshot root, one replaced once
/// bound, a colliding final generation).
///
/// Swift reads numbers through `JSONSerialization` and `JSONDecoder`, and
/// digests through `Character.isHexDigit`, so the cases pin what those accept
/// at the edges (a format version of `1.0` or `true`, a byte count of `12.0`,
/// a stapled flag of `1`, a fullwidth digest).
///
/// The oracle records every input entry before the first load (kind, mode,
/// link target, a file's digest, and its text once by that digest in
/// `blobs.json`), each case's outcome with every trust contract and doctor
/// contract the loader handed out, and every entry left afterwards (file
/// digests, modes, link targets). Every mode it records is one the oracle or
/// the loader sets explicitly, never the process's file mode creation mask
/// (`run-swiftpm.sh` runs under `077`); a link's own mode is not recorded.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ARKTRACE_PROFILE_LOADER_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ArkTraceProfileLoaderOracleContractTests: XCTestCase {
  static let root = "/private/tmp/arkdeck-arktrace-oracle"
  static let lockPath = "/private/tmp/arkdeck-arktrace-oracle.lock"
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/arktrace-profile-loader", directoryHint: .isDirectory)

  /// Serializes every user of the fixed root, the Rust replay included.
  static func lock() throws -> Int32 {
    let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    guard flock(lock, LOCK_EX) == 0 else {
      close(lock)
      throw POSIXError(.EBUSY)
    }
    return lock
  }

  // MARK: Stubs

  final class Doctor: ArkTraceDoctorProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private(set) var contracts: [ArkTraceDoctorContract] = []
    init(result: Bool) { self.result = result }
    func probe(_ contract: ArkTraceDoctorContract) async -> Bool {
      lock.withLock { contracts.append(contract) }
      return result
    }
  }

  /// `digest`: the App tree's digest, as the contract tests' stub answers;
  /// `tree`: the App tree's files and digest, the evidence the production
  /// checker returns once the code signatures hold; `refuse`: a contract
  /// mismatch; `replaceRoot`: the distribution root moved aside and a link
  /// left in its place, then no evidence.
  final class Trust: ArkTraceDistributionTrustChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let mode: String
    private let caseRoot: String
    private(set) var contracts: [ArkTraceDistributionTrustContract] = []
    init(mode: String, caseRoot: String) {
      self.mode = mode
      self.caseRoot = caseRoot
    }
    func validate(
      _ contract: ArkTraceDistributionTrustContract
    ) throws -> ArkTraceDistributionTrustEvidence {
      lock.withLock { contracts.append(contract) }
      switch mode {
      case "digest":
        return ArkTraceDistributionTrustEvidence(
          pinnedTrees: [
            AnalyzerPinnedTree(
              path: contract.appPath,
              sha256: try ArkTraceDistributionTreeHasher.digest(rootPath: contract.appPath))
          ])
      case "tree":
        let tree = try ArkTraceDistributionTreeHasher.snapshot(rootPath: contract.appPath)
        return ArkTraceDistributionTrustEvidence(
          pinnedFiles: tree.pinnedFiles,
          pinnedTrees: [AnalyzerPinnedTree(path: contract.appPath, sha256: tree.sha256)])
      case "replaceRoot":
        let distribution = caseRoot + "/distribution"
        let held = caseRoot + "/held-distribution"
        guard rename(distribution, held) == 0, symlink(held, distribution) == 0 else {
          throw POSIXError(.EIO)
        }
        return ArkTraceDistributionTrustEvidence()
      default:
        throw ArkTraceSummaryProfileError.contractMismatch
      }
    }
  }

  // MARK: Cases

  struct Case {
    let name: String
    /// The trust checker's mode.
    var trust = "digest"
    var doctor = true
    /// Relative to the case directory.
    var snapshotRoot: String?
    /// `replaceBoundSnapshotRoot` or `collideFinalGeneration`.
    var hook: String?
    /// How many times the case loads.
    var loads = 1
    /// Relative to the case directory, or absolute.
    var descriptor = "descriptor.json"
  }

  static let cases: [Case] = [
    Case(name: "valid"),
    Case(name: "validTreeTrust", trust: "tree"),
    Case(name: "snapshot", trust: "tree", snapshotRoot: "state/arktrace-profile-snapshots", loads: 2),
    Case(name: "snapshotRootLink", snapshotRoot: "arktrace-profile-snapshots"),
    Case(
      name: "snapshotRootReplaced", snapshotRoot: "bound-snapshot-root",
      hook: "replaceBoundSnapshotRoot"),
    Case(
      name: "publicationCollision", snapshotRoot: "collision-snapshot-root",
      hook: "collideFinalGeneration", loads: 2),
    Case(name: "descriptorMissing", descriptor: "missing.json"),
    Case(name: "descriptorWritable"),
    Case(name: "descriptorLinkedRoot"),
    Case(name: "descriptorNotJSON"),
    Case(name: "descriptorArray"),
    Case(name: "descriptorExtraKey"),
    Case(name: "descriptorFormat2"),
    Case(name: "descriptorFormatString"),
    Case(name: "descriptorFormatFloat"),
    Case(name: "descriptorFormatTrue"),
    Case(name: "descriptorRelativeRoot"),
    Case(name: "descriptorUppercaseDigest"),
    Case(name: "descriptorFullwidthDigest"),
    Case(name: "descriptorDuplicateKey"),
    Case(name: "descriptorTooLarge"),
    Case(name: "rootMissing"),
    Case(name: "rootWritable"),
    Case(name: "manifestMissing"),
    Case(name: "manifestAppended"),
    Case(name: "manifestDuplicateKey"),
    Case(name: "manifestExtraKey"),
    Case(name: "manifestProductVersion"),
    Case(name: "manifestByteCountFloat"),
    Case(name: "manifestByteCountString"),
    Case(name: "manifestStapledNumber"),
    Case(name: "manifestReceiptTraversal"),
    Case(name: "manifestResourceBundleAbsolute"),
    Case(name: "toolDrift"),
    Case(name: "toolNotExecutable"),
    Case(name: "parserDrift"),
    Case(name: "parserManifestDrift"),
    Case(name: "signingRecordDrift"),
    Case(name: "receiptMissing"),
    Case(name: "receiptDrift"),
    Case(name: "trustRefused", trust: "refuse"),
    Case(name: "trustReplacesRoot", trust: "replaceRoot"),
    Case(name: "doctorFails", doctor: false),
    Case(name: "layoutLinkedHelpers"),
    Case(name: "ancestorWritable"),
    Case(name: "treeEntryWritable"),
  ]

  // MARK: Distribution

  static let toolBytes = Data("#!/bin/sh\n# ArkTrace CLI oracle stand-in; never run.\nexit 64\n".utf8)
  static let parserBytes = Data("#!/bin/sh\n# trace_streamer oracle stand-in; never run.\nexit 64\n".utf8)
  static let parserManifestBytes = Data("{\"binary\":\"signed\"}\n".utf8)
  static let signingRecordBytes = Data("{\"signed\":true}\n".utf8)
  static let receiptBytes = Data("{\"status\":\"Accepted\"}\n".utf8)
  static let inventoryBytes = Data("{\"licenses\":[]}\n".utf8)
  static let infoBytes = Data("<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict/></plist>\n".utf8)

  static func sha256(_ data: Data) -> String { AnalyzerProvider.sha256(data) }

  static func manifestObject(productVersion: String = "0.1.0") -> [String: Any] {
    [
      "formatVersion": 1,
      "source": [
        "revision": String(repeating: "1", count: 40),
        "treeSHA256": String(repeating: "2", count: 64),
      ],
      "product": [
        "name": "arktrace", "version": productVersion, "build": "1",
        "architecture": "arm64", "bundleIdentifier": "com.arktrace.ArkTrace.CLI",
        "jsonContract": ["major": 1, "minor": 0],
      ],
      "layout": [
        "bundle": "ArkTraceCLI.app",
        "executable": "ArkTraceCLI.app/Contents/MacOS/arktrace",
        "parserExecutable": "ArkTraceCLI.app/Contents/Helpers/trace_streamer",
        "parserManifest": "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json",
        "parserSigningRecord":
          "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json",
        "resourceBundle": "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources",
      ],
      "tool": [
        "binarySHA256": sha256(toolBytes), "byteCount": toolBytes.count,
        "codeDirectoryHash": String(repeating: "3", count: 40),
      ],
      "traceStreamer": [
        "unsignedBinarySHA256": String(repeating: "4", count: 64),
        "binarySHA256": sha256(parserBytes), "byteCount": parserBytes.count,
        "codeDirectoryHash": String(repeating: "5", count: 40),
        "manifestSHA256": sha256(parserManifestBytes),
        "manifestByteCount": parserManifestBytes.count,
        "signingRecordSHA256": sha256(signingRecordBytes),
        "signingRecordByteCount": signingRecordBytes.count,
        "reportedVersion": "4.3.7",
        "upstreamRevision": String(repeating: "6", count: 40),
        "buildRecipeVersion": String(repeating: "7", count: 64),
      ],
      "signing": [
        "teamIdentifier": "TEAM123456", "identity": "Developer ID Application: Oracle",
        "certificateSHA1": String(repeating: "A", count: 40),
        "policy": "developer-id-runtime-timestamp",
      ],
      "notarization": [
        "status": "Accepted", "submissionID": "00000000-0000-4000-8000-000000000000",
        "receipt": "notarization-receipt.json",
        "receiptSHA256": sha256(receiptBytes),
        "stapledTicketValidated": true, "gatekeeperAssessment": "accepted",
      ],
      "integrity": [
        "appTreeSHA256": String(repeating: "8", count: 64),
        "resourceTreeSHA256": String(repeating: "9", count: 64),
        "appCodeDirectoryHash": String(repeating: "a", count: 40),
      ],
      "attribution": [
        "license": "LICENSE", "licenseSHA256": String(repeating: "a", count: 64),
        "licenseByteCount": 1, "notice": "THIRD_PARTY_NOTICES.md",
        "noticeSHA256": String(repeating: "b", count: 64), "noticeByteCount": 1,
        "inventory":
          "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources/license-inventory.json",
        "inventorySHA256": String(repeating: "c", count: 64), "inventoryByteCount": 1,
        "licenseFileCount": 18,
        "selfTestFixture": "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources/zlib.htrace",
        "selfTestFixtureSHA256": String(repeating: "d", count: 64),
        "selfTestFixtureByteCount": 1,
      ],
      "upgradePolicy": [
        "identity": "distribution-manifest+tool-parser-hashes",
        "installMode": "versioned-directory",
        "pathSelection": "reviewed-absolute-descriptor-only",
        "rollback": "retain-prior-exact-directory",
      ],
    ]
  }

  static func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  static func write(_ data: Data, _ path: String, mode: mode_t) throws {
    try data.write(to: URL(filePath: path))
    guard chmod(path, mode) == 0 else { throw POSIXError(.EPERM) }
  }

  static func directory(_ path: String, mode: mode_t = 0o755) throws {
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true, attributes: nil)
    guard chmod(path, mode) == 0 else { throw POSIXError(.EPERM) }
  }

  /// One case's distribution and descriptor, altered as the case names.
  static func build(_ item: Case) throws {
    let caseRoot = "\(root)/\(item.name)"
    let distribution = "\(caseRoot)/distribution"
    let app = "\(distribution)/ArkTraceCLI.app/Contents"
    try directory(caseRoot)
    for path in [
      "\(app)/MacOS", "\(app)/Helpers", "\(app)/Resources/TraceStreamer",
      "\(app)/Resources/ArkTraceCLIResources",
    ] {
      try directory(path)
    }
    for path in [
      distribution, "\(distribution)/ArkTraceCLI.app", app, "\(app)/Resources",
    ] {
      guard chmod(path, 0o755) == 0 else { throw POSIXError(.EPERM) }
    }
    var tool = toolBytes
    var toolMode: mode_t = 0o755
    var parser = parserBytes
    var parserManifest = parserManifestBytes
    var signingRecord = signingRecordBytes
    var receipt: Data? = receiptBytes
    switch item.name {
    case "toolDrift": tool = Data("#!/bin/sh\nexit 0\n".utf8)
    case "toolNotExecutable": toolMode = 0o644
    case "parserDrift": parser = Data("parser drift".utf8)
    case "parserManifestDrift": parserManifest = Data("{\"binary\":\"drifted\"}\n".utf8)
    case "signingRecordDrift": signingRecord = Data("{\"signed\":false}\n".utf8)
    case "receiptMissing": receipt = nil
    case "receiptDrift": receipt = Data("{\"status\":\"Rejected\"}\n".utf8)
    default: break
    }
    try write(tool, "\(app)/MacOS/arktrace", mode: toolMode)
    try write(parser, "\(app)/Helpers/trace_streamer", mode: 0o755)
    try write(parserManifest, "\(app)/Resources/TraceStreamer/manifest.json", mode: 0o644)
    try write(
      signingRecord, "\(app)/Resources/TraceStreamer/distribution-signing.json", mode: 0o644)
    try write(
      inventoryBytes, "\(app)/Resources/ArkTraceCLIResources/license-inventory.json",
      mode: item.name == "treeEntryWritable" ? 0o666 : 0o644)
    try write(infoBytes, "\(app)/Info.plist", mode: 0o644)
    if let receipt {
      try write(receipt, "\(distribution)/notarization-receipt.json", mode: 0o644)
    }
    if item.name == "layoutLinkedHelpers" {
      let moved = "\(caseRoot)/helpers-elsewhere"
      guard rename("\(app)/Helpers", moved) == 0, symlink(moved, "\(app)/Helpers") == 0 else {
        throw POSIXError(.EIO)
      }
    }

    var manifestObject = manifestObject(
      productVersion: item.name == "manifestProductVersion" ? "9.0.0" : "0.1.0")
    switch item.name {
    case "manifestExtraKey": manifestObject["extra"] = true
    case "manifestByteCountString":
      var toolFields = manifestObject["tool"] as! [String: Any]
      toolFields["byteCount"] = String(toolBytes.count)
      manifestObject["tool"] = toolFields
    case "manifestReceiptTraversal":
      var notarization = manifestObject["notarization"] as! [String: Any]
      notarization["receipt"] = "../notarization-receipt.json"
      manifestObject["notarization"] = notarization
    case "manifestResourceBundleAbsolute":
      var layout = manifestObject["layout"] as! [String: Any]
      layout["resourceBundle"] = "/private/tmp"
      manifestObject["layout"] = layout
    default: break
    }
    var manifest = String(decoding: try json(manifestObject), as: UTF8.self)
    switch item.name {
    case "manifestDuplicateKey":
      manifest = "{\"formatVersion\":1," + manifest.dropFirst()
    case "manifestByteCountFloat":
      manifest = manifest.replacingOccurrences(
        of: "\"byteCount\":\(toolBytes.count),\"codeDirectoryHash\":\"3",
        with: "\"byteCount\":\(toolBytes.count).0,\"codeDirectoryHash\":\"3")
    case "manifestStapledNumber":
      manifest = manifest.replacingOccurrences(
        of: "\"stapledTicketValidated\":true", with: "\"stapledTicketValidated\":1")
    default: break
    }
    let manifestData = Data(manifest.utf8)
    let manifestSHA256 = sha256(manifestData)
    if item.name != "manifestMissing" {
      var written = manifestData
      if item.name == "manifestAppended" { written.append(0x20) }
      try write(written, "\(distribution)/distribution-manifest.json", mode: 0o644)
    }

    var rootPath = distribution
    switch item.name {
    case "descriptorLinkedRoot":
      rootPath = "\(caseRoot)/linked-distribution"
      guard symlink(distribution, rootPath) == 0 else { throw POSIXError(.EIO) }
    case "descriptorRelativeRoot": rootPath = "distribution"
    case "rootMissing": rootPath = "\(caseRoot)/absent-distribution"
    case "rootWritable": guard chmod(distribution, 0o777) == 0 else { throw POSIXError(.EPERM) }
    default: break
    }
    var descriptorObject: [String: Any] = [
      "formatVersion": 1, "distributionRoot": rootPath, "manifestSHA256": manifestSHA256,
    ]
    switch item.name {
    case "descriptorExtraKey": descriptorObject["extra"] = "value"
    case "descriptorFormat2": descriptorObject["formatVersion"] = 2
    case "descriptorFormatString": descriptorObject["formatVersion"] = "1"
    case "descriptorFormatTrue": descriptorObject["formatVersion"] = true
    case "descriptorUppercaseDigest": descriptorObject["manifestSHA256"] = manifestSHA256.uppercased()
    case "descriptorFullwidthDigest":
      descriptorObject["manifestSHA256"] = String(
        manifestSHA256.unicodeScalars.map { scalar -> Character in
          switch scalar.value {
          case 0x30...0x39: return Character(UnicodeScalar(scalar.value - 0x30 + 0xFF10)!)
          case 0x61...0x66: return Character(UnicodeScalar(scalar.value - 0x61 + 0xFF41)!)
          default: return Character(scalar)
          }
        })
    default: break
    }
    var descriptor = String(decoding: try json(descriptorObject), as: UTF8.self)
    switch item.name {
    case "descriptorNotJSON": descriptor = "{\"formatVersion\":1,"
    case "descriptorArray": descriptor = "[]"
    case "descriptorFormatFloat":
      descriptor = descriptor.replacingOccurrences(
        of: "\"formatVersion\":1", with: "\"formatVersion\":1.0")
    case "descriptorDuplicateKey": descriptor = "{\"formatVersion\":1," + descriptor.dropFirst()
    case "descriptorTooLarge":
      descriptor = String(descriptor.dropLast()) + ",\"padding\":\""
        + String(repeating: "x", count: 16 * 1024) + "\"}"
    default: break
    }
    if item.name != "descriptorMissing" {
      try write(
        Data(descriptor.utf8), "\(caseRoot)/descriptor.json",
        mode: item.name == "descriptorWritable" ? 0o666 : 0o644)
    }
    switch item.name {
    case "snapshotRootLink":
      try directory("\(caseRoot)/foreign-snapshot-target")
      guard symlink(
        "\(caseRoot)/foreign-snapshot-target", "\(caseRoot)/arktrace-profile-snapshots") == 0
      else { throw POSIXError(.EIO) }
    case "snapshotRootReplaced":
      try directory("\(caseRoot)/bound-snapshot-root", mode: 0o700)
      try directory("\(caseRoot)/foreign-replacement-root", mode: 0o700)
      try write(
        Data("must remain the only foreign entry".utf8),
        "\(caseRoot)/foreign-replacement-root/foreign-sentinel.txt", mode: 0o644)
    case "publicationCollision":
      try directory("\(caseRoot)/collision-snapshot-root", mode: 0o700)
    case "ancestorWritable":
      guard chmod(caseRoot, 0o777) == 0 else { throw POSIXError(.EPERM) }
    default: break
    }
  }

  // MARK: Projections

  static func projection(_ profile: AnalyzerProfile) -> JSONValue {
    func contract(_ value: ArkTraceSummaryInvocationContract?) -> JSONValue {
      guard let value else { return .null }
      return .object([
        "toolVersion": .string(value.toolVersion),
        "parserVersion": .string(value.parserVersion),
        "parserUpstreamRevision": .string(value.parserUpstreamRevision),
        "parserSHA256": .string(value.parserSHA256),
        "parserBuildRecipeVersion": .string(value.parserBuildRecipeVersion),
        "parserAdapterVersion": .string(value.parserAdapterVersion),
        "schemaAdapterVersion": .string(value.schemaAdapterVersion),
        "indexSchemaVersion": .integer(Int64(value.indexSchemaVersion)),
      ])
    }
    return .object([
      "analyzerRef": .string(profile.analyzerRef),
      "analyzerVersion": .string(profile.analyzerVersion),
      "executablePath": .string(profile.executablePath),
      "executableSHA256": .string(profile.executableSHA256),
      "canonicalNamespaceRoot": profile.canonicalNamespaceRoot.map(JSONValue.string) ?? .null,
      "fixedArguments": .array(profile.fixedArguments.map(JSONValue.string)),
      "timeoutSeconds": .integer(Int64(profile.timeoutSeconds)),
      "outputByteBudget": .integer(Int64(profile.outputByteBudget)),
      "pinnedFiles": .array(
        profile.pinnedFiles.map {
          .object([
            "path": .string($0.path), "sha256": .string($0.sha256),
            "byteCount": .integer(Int64($0.byteCount)),
            "requireExecutable": .bool($0.requireExecutable),
          ])
        }),
      "pinnedTrees": .array(
        profile.pinnedTrees.map {
          .object(["path": .string($0.path), "sha256": .string($0.sha256)])
        }),
      "preflightAvailable": .bool(profile.preflightAvailability == .available),
      "arkTraceSummaryContract": contract(profile.arkTraceSummaryContract),
      "arkTraceAnalysisContract": contract(profile.arkTraceAnalysisContract),
    ])
  }

  static func projection(_ contract: ArkTraceDistributionTrustContract) -> JSONValue {
    .object([
      "appPath": .string(contract.appPath),
      "helperPath": .string(contract.helperPath),
      "resourcePath": .string(contract.resourcePath),
      "productVersion": .string(contract.productVersion),
      "productBuild": .string(contract.productBuild),
      "bundleIdentifier": .string(contract.bundleIdentifier),
      "teamIdentifier": .string(contract.teamIdentifier),
      "signingIdentity": .string(contract.signingIdentity),
      "certificateSHA1": .string(contract.certificateSHA1),
      "appCodeDirectoryHash": .string(contract.appCodeDirectoryHash),
      "helperCodeDirectoryHash": .string(contract.helperCodeDirectoryHash),
      "appTreeSHA256": .string(contract.appTreeSHA256),
      "resourceTreeSHA256": .string(contract.resourceTreeSHA256),
    ])
  }

  static func projection(_ contract: ArkTraceDoctorContract) -> JSONValue {
    let executable = contract.executable
    return .object([
      "executable": .object([
        "path": .string(executable.path),
        "sha256": .string(executable.sha256),
        "verifiedResources": .array(
          executable.verifiedResources.map {
            .object([
              "path": .string($0.path), "sha256": .string($0.sha256),
              "byteCount": .integer(Int64($0.byteCount)),
              "requireExecutable": .bool($0.requireExecutable),
            ])
          }),
        "verifiedTrees": .array(
          executable.verifiedTrees.map {
            .object(["path": .string($0.path), "sha256": .string($0.sha256)])
          }),
        "canonicalNamespaceRoot": executable.canonicalNamespaceRoot.map(JSONValue.string)
          ?? .null,
      ]),
      "productVersion": .string(contract.productVersion),
      "timeoutSeconds": .integer(Int64(contract.timeoutSeconds)),
      "outputByteBudget": .integer(Int64(contract.outputByteBudget)),
    ])
  }

  /// Every entry below the root in path order: its kind, its permission
  /// bits, a link's target, and a file's digest and length; with `blobs`,
  /// each file's text is kept there once, by its digest.
  static func tree(blobs: inout [String: JSONValue]?) throws -> JSONValue {
    var entries: [JSONValue] = []
    for path in try FileManager.default.subpathsOfDirectory(atPath: root).sorted() {
      let full = "\(root)/\(path)"
      var metadata = stat()
      guard lstat(full, &metadata) == 0 else { throw POSIXError(.EIO) }
      var entry: [String: JSONValue] = ["path": .string(path)]
      // A link's own mode is the creating process's mask, not the loader's.
      if metadata.st_mode & S_IFMT != S_IFLNK {
        entry["mode"] = .string(String(metadata.st_mode & 0o7777, radix: 8))
      }
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR: entry["kind"] = .string("directory")
      case S_IFLNK:
        entry["kind"] = .string("link")
        entry["target"] = .string(try FileManager.default.destinationOfSymbolicLink(atPath: full))
      case S_IFREG:
        entry["kind"] = .string("file")
        let data = try Data(contentsOf: URL(filePath: full))
        entry["sha256"] = .string(sha256(data))
        entry["byteCount"] = .integer(Int64(data.count))
        if blobs != nil {
          guard let text = String(data: data, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
          blobs?[sha256(data)] = .string(text)
        }
      default: throw POSIXError(.EFTYPE)
      }
      entries.append(.object(entry))
    }
    return .array(entries)
  }

  /// The process's file mode creation mask, which the loader's own
  /// directories are made under.
  static func umaskBits() -> mode_t {
    let mask = umask(0)
    umask(mask)
    return mask
  }

  // MARK: Oracle

  func testSwiftLoadsTheSharedArkTraceDistributions() async throws {
    let lock = try Self.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_ARKTRACE_PROFILE_LOADER_RECORD",
      oracle: Self.oracle)
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    try? manager.removeItem(atPath: Self.root)
    defer { try? manager.removeItem(atPath: Self.root) }
    try Self.directory(Self.root, mode: 0o700)
    for item in Self.cases { try Self.build(item) }
    var blobs: [String: JSONValue]? = [:]
    let inputs = try Self.tree(blobs: &blobs)

    var recorded: [JSONValue] = []
    for item in Self.cases {
      let caseRoot = "\(Self.root)/\(item.name)"
      let doctor = Doctor(result: item.doctor)
      let trust = Trust(mode: item.trust, caseRoot: caseRoot)
      let snapshotRoot = item.snapshotRoot.map {
        URL(filePath: "\(caseRoot)/\($0)", directoryHint: .isDirectory)
      }
      let bound: @Sendable () throws -> Void
      let beforePublication: @Sendable (String) throws -> Void
      switch item.hook {
      case "replaceBoundSnapshotRoot":
        bound = {
          guard rename("\(caseRoot)/bound-snapshot-root", "\(caseRoot)/held-bound-snapshot-root")
            == 0,
            rename("\(caseRoot)/foreign-replacement-root", "\(caseRoot)/bound-snapshot-root") == 0
          else { throw POSIXError(.EIO) }
        }
        beforePublication = { _ in }
      case "collideFinalGeneration":
        bound = {}
        beforePublication = { name in
          let final = "\(caseRoot)/collision-snapshot-root/\(name)"
          guard mkdir(final, 0o755) == 0, chmod(final, 0o755) == 0 else {
            throw POSIXError(.EIO)
          }
          try Self.write(
            Data("pre-existing invalid generation".utf8), "\(final)/sentinel.txt", mode: 0o644)
        }
      default:
        bound = {}
        beforePublication = { _ in }
      }
      let loader = ArkTraceSummaryAnalyzerProfileLoader(
        doctor: doctor, trustChecker: trust, snapshotRootURL: snapshotRoot,
        snapshotRootBoundHook: bound, beforeSnapshotPublicationHook: beforePublication)
      let descriptor =
        item.descriptor.hasPrefix("/") ? item.descriptor : "\(caseRoot)/\(item.descriptor)"
      var outcomes: [JSONValue] = []
      for _ in 0..<item.loads {
        do {
          let profiles = try await loader.loadProfiles(descriptorURL: URL(filePath: descriptor))
          outcomes.append(.object(["profiles": .array(profiles.map(Self.projection))]))
        } catch let error as ArkTraceSummaryProfileError {
          outcomes.append(.object(["error": .string(error.reason), "thrown": .string("profile")]))
        } catch {
          outcomes.append(
            .object([
              "error": .string(ArkTraceSummaryProfileError.descriptorInvalid.reason),
              "thrown": .string("other"),
            ]))
        }
      }
      recorded.append(
        .object([
          "name": .string(item.name),
          "trust": .string(item.trust),
          "doctor": .bool(item.doctor),
          "snapshotRoot": item.snapshotRoot.map(JSONValue.string) ?? .null,
          "hook": item.hook.map(JSONValue.string) ?? .null,
          "descriptor": .string(descriptor),
          "outcomes": .array(outcomes),
          "trustContracts": .array(trust.contracts.map(Self.projection)),
          "doctorContracts": .array(doctor.contracts.map(Self.projection)),
        ]))
    }
    var none: [String: JSONValue]? = nil
    let after = try Self.tree(blobs: &none)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "cases.json": try encoder.encode(JSONValue.array(recorded)) + Data("\n".utf8),
      "inputs.json": try encoder.encode(inputs) + Data("\n".utf8),
      "blobs.json": try encoder.encode(JSONValue.object(blobs ?? [:])) + Data("\n".utf8),
      "after.json": try encoder.encode(after) + Data("\n".utf8),
    ]
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(Self.sha256(data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "ArkTraceProfileLoaderOracleContractTests.testSwiftLoadsTheSharedArkTraceDistributions"),
          "root": .string(Self.root),
          "umask": .string(String(Self.umaskBits(), radix: 8)),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }
}
