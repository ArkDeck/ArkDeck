// Shared Swift oracle for the Rust Runtime's Flash `job.plan`
// (CHG-2026-074, TASK-XPA-017, milestone M4).

import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

/// Swift `job.plan` for the canonical Flash operation (`flash.full-restore@1`)
/// and its compatibility alias (`flash.dayu200`), through the daemon's
/// control-plane handler over `RuntimeJobEngine.planOnly`.
///
/// The flash bundle is imported first, through the same handler with the
/// production policy. Its lease is what every request names. The Artifact
/// root it leaves is recorded as the replay's input (`inputs/`).
///
/// Everything the plan reads beyond that bundle is scripted per exchange, and
/// the exchange's setup names it:
///
/// - the provider's runtime availability, as the ArkForge lane's composition
///   decides it;
/// - the dispatcher's unavailable reason;
/// - the lane's toolchain digest, or no lane;
/// - the ArkForge facts port's answer, or its error. That port has its own
///   oracle (`flash-host-facts`).
///
/// The dispatcher's reason is then recorded apart (`dispatch.json`), from
/// Swift's own Rockchip dispatcher as the daemon composes it: the configured
/// `arkforged`'s identity, then the per-action host without an HDC, and with
/// one over each state its durable record root can be found in.
///
/// No device, ArkForge daemon, HDC or dispatch is involved; every request is
/// plan-only.
///
/// Record a new oracle with
/// `ARKDECK_RUST_FLASH_PLAN_RECORD=/private/tmp/<new directory>`. An Import
/// is named at random, so otherwise nothing is imported: the checked-in
/// Artifact root and Target store are laid down as the Rust replay lays them
/// down, every recorded request is planned again under its recorded setup,
/// and the answers, the tree they leave and the dispatcher's reasons must
/// match the checked-in oracle byte for byte.
final class FlashPlanOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/flash-plan", directoryHint: .isDirectory)
  private static let archives = repository.appending(
    path: "rust/tests/fixtures/flash-archive/archives", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_FLASH_PLAN_RECORD"
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-flash-plan-oracle", directoryHint: .isDirectory)
  /// Where the dispatcher's record roots are laid out: a path Swift's
  /// canonical check accepts once it exists, which none below `/private` is.
  private static let dispatchRoot = URL(
    filePath: "/tmp/arkdeck-flash-plan-dispatch", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-25T00:00:00Z"
  private static let connectKey = "150100424a544e4600"
  private static let aliasKey = "post-flash-hdc-address"
  private static let toolchain = String(repeating: "c", count: 64)
  private static let arkforged = String(repeating: "b", count: 64)

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// A lane that only names the toolchain its StepPermits bind; plan-only
  /// never calls it.
  private actor Lane: RuntimeJobEngine.ArkForgeLane {
    nonisolated let toolchainSHA256: String

    init(toolchainSHA256: String) { self.toolchainSHA256 = toolchainSHA256 }

    func prepareExecution(
      jobID _: String, artifact _: ArkForgeLaneArtifact,
      binding _: ArkForgeLaneDeviceBinding, executionPurpose _: String
    ) async throws -> RuntimeArkForgeLaneExecution {
      throw RuntimeDispatchFailure.failed("plan-only never prepares an execution")
    }

    func performPrepared(
      stepID: String, execution _: RuntimeArkForgeLaneExecution,
      artifact _: ArkForgeLaneArtifact, binding _: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary {
      throw RuntimeDispatchFailure.failed("plan-only never performs \(stepID)")
    }

    func observeTerminal(
      execution _: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome? {
      throw RuntimeDispatchFailure.failed("plan-only never observes an execution")
    }

    func completedPlanReceipt(jobID _: String) async -> ArkForgeActionReceiptSummary? { nil }
  }

  private struct Dispatcher: RuntimeProcessDispatching {
    let reason: String?

    func unavailableReason(providerID _: String) -> String? { reason }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      throw RuntimeDispatchFailure.failed("plan-only never dispatches")
    }
  }

  private struct Facts: RockchipRuntimeFactsPort {
    let answer: Result<ProviderFacts, DeviceProviderError>

    func currentFacts(targetID _: String) async throws -> ProviderFacts {
      try answer.get()
    }
  }

  /// What one exchange's plan reads besides the bundle.
  private struct Setup {
    var unavailable: String? = nil
    var dispatchUnavailable: String? = nil
    var toolchain: String? = FlashPlanOracleContractTests.toolchain
    var facts: [String: JSONValue]? = FlashPlanOracleContractTests.facts()
    var factsError: String? = nil

    init(
      unavailable: String? = nil, dispatchUnavailable: String? = nil,
      toolchain: String? = FlashPlanOracleContractTests.toolchain,
      facts: [String: JSONValue]? = FlashPlanOracleContractTests.facts(),
      factsError: String? = nil
    ) {
      self.unavailable = unavailable
      self.dispatchUnavailable = dispatchUnavailable
      self.toolchain = toolchain
      self.facts = facts
      self.factsError = factsError
    }

    /// The setup an exchange recorded.
    init(recorded: JSONValue) throws {
      guard case .object(let fields) = recorded else { throw CocoaError(.coderInvalidValue) }
      func text(_ key: String) -> String? {
        if case .string(let value)? = fields[key] { return value }
        return nil
      }
      unavailable = text("unavailable")
      dispatchUnavailable = text("dispatchUnavailable")
      toolchain = text("toolchainSha256")
      switch fields["facts"] {
      case .object(let facts)? where facts["error"] != nil:
        guard case .string(let error)? = facts["error"] else { throw CocoaError(.coderInvalidValue) }
        self.facts = nil
        factsError = error
      case .object(let facts)?:
        self.facts = facts
        factsError = nil
      default:
        facts = nil
        factsError = nil
      }
    }

    var recorded: JSONValue {
      .object([
        "unavailable": unavailable.map(JSONValue.string) ?? .null,
        "dispatchUnavailable": dispatchUnavailable.map(JSONValue.string) ?? .null,
        "toolchainSha256": toolchain.map(JSONValue.string) ?? .null,
        "facts": factsError.map { .object(["error": .string($0)]) }
          ?? facts.map(JSONValue.object) ?? .null,
      ])
    }
  }

  /// The facts a covered, post-flash-routed DAYU200 answers with.
  private static func facts(
    bindingRevision: Int = 1, connectKey: String = aliasKey,
    identity: String? = nil, tool: String = arkforged,
    crossMode: String = "satisfied", aliasIdentity: String? = nil,
    aliasTopology: String? = "42"
  ) -> [String: JSONValue] {
    var server: [String: JSONValue] = [
      "rockusbBackend": .string("native"),
      "arkForgeToolchainID": .string(ArkForgeNativeRockUSBToolchain.identifier),
      "dayu200CrossModeBinding": .string(crossMode),
    ]
    if let aliasTopology {
      server["dayu200HDCNormalAliasSHA256"] = .string(aliasIdentity ?? digest(connectKey))
      server["dayu200HDCNormalAliasUSBTopology"] = .string(aliasTopology)
    }
    return [
      "bindingRevision": .integer(Int64(bindingRevision)),
      "executionConnectKey": .string(connectKey),
      "deviceIdentitySha256": .string(identity ?? digest(FlashPlanOracleContractTests.connectKey)),
      "toolSha256": .string(tool),
      "serverFacts": .object(server),
    ]
  }

  private static func providerFacts(
    _ facts: [String: JSONValue], targetID: String
  ) throws -> ProviderFacts {
    guard case .integer(let revision)? = facts["bindingRevision"],
      case .string(let key)? = facts["executionConnectKey"],
      case .string(let identity)? = facts["deviceIdentitySha256"],
      case .string(let tool)? = facts["toolSha256"],
      case .object(let serverValues)? = facts["serverFacts"]
    else { throw CocoaError(.coderInvalidValue) }
    var server: [String: String] = [:]
    for (key, value) in serverValues {
      guard case .string(let text) = value else { throw CocoaError(.coderInvalidValue) }
      server[key] = text
    }
    return ProviderFacts(
      providerID: CatalogProvider.arkforge.rawValue,
      toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
      toolSHA256: tool, serverFacts: server, targetID: targetID,
      bindingRevision: Int(revision), deviceIdentitySHA256: identity,
      executionConnectKey: key, deviceMode: "hdc", buildFingerprint: nil,
      profileID: "dayu200", collectedAtUTC: nowUTC)
  }

  private var targets: RuntimeTargetStore!
  private var artifacts: RuntimeArtifactStore!
  private var target: RuntimeTargetRecord!
  private var engineCount = 0

  override func setUpWithError() throws {
    for root in [Self.root, Self.dispatchRoot] {
      try? FileManager.default.removeItem(at: root)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }

  override func tearDownWithError() throws {
    artifacts = nil; targets = nil
    for root in [Self.root, Self.dispatchRoot] { try? FileManager.default.removeItem(at: root) }
  }

  /// The Target and Artifact stores over the oracle's root, as it is now.
  private func openStores() throws {
    targets = try RuntimeTargetStore(directoryURL: Self.root.appending(path: "targets"))
    artifacts = try RuntimeArtifactStore(
      rootURL: Self.root.appending(path: "artifacts"), nowUTC: { Self.nowUTC })
  }

  private func handler(_ setup: Setup) throws -> RuntimeControlPlaneHandler {
    engineCount += 1
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: Self.root.appending(path: "engines/\(engineCount)/capabilities"))
    let facts: Result<ProviderFacts, DeviceProviderError>
    if let error = setup.factsError {
      facts = .failure(.factsUnavailable(error))
    } else {
      facts = .success(try Self.providerFacts(setup.facts ?? [:], targetID: target.targetID))
    }
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: Self.root.appending(path: "engines/\(engineCount)/state"),
        arkForgeLane: setup.toolchain.map { Lane(toolchainSHA256: $0) },
        arkForgeDeviceProfileID: "dayu200"),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(
          factsPort: Facts(answer: facts),
          availability: setup.unavailable.map {
            .unavailable(code: .providerToolUnavailable, reason: $0)
          } ?? .available)
      ]),
      dispatcher: Dispatcher(reason: setup.dispatchUnavailable),
      capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { Self.nowUTC })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: ["arkforge"],
      nowUTC: { Self.nowUTC }, targetStore: targets, bootstrap: nil,
      artifactStore: artifacts, flashBundleImportDirectory: nil,
      flashBundleImportPolicy: .production, methodObserver: nil)
  }

  private func call(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let request = try ArkDeckAgentXPC.requestFrame(
      method: method, params: params, requestID: "flash-plan")
    let response = try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: await handler.handleLine(request))
    if let error = response.error {
      return .object([
        "ok": .bool(false),
        "error": .object([
          "code": .string(error.code), "message": .string(error.message),
          "details": error.details.map(JSONValue.object) ?? .null,
        ]),
      ])
    }
    return .object(["ok": .bool(true), "result": response.result ?? .null])
  }

  /// Imports `archive` for `targetID` and answers its lease.
  private func importBundle(_ request: String, archive: String) async throws -> String {
    let bytes = try Data(contentsOf: Self.archives.appending(path: archive))
    let handler = try handler(Setup())
    let began = try await call(
      handler, "artifact.import.begin",
      [
        "schemaVersion": .string(ArtifactImportIntent.schemaVersion),
        "importRequestId": .string(request), "kind": .string("flash-bundle"),
        "targetId": .string(target.targetID),
        "bindingRevision": .string(String(target.bindingRevision)),
        "deviceProfile": .string("dayu200"), "name": .string("images.tar.gz"),
        "byteCount": .string(String(bytes.count)),
        "sha256": .string(SHA256Hex.string(of: bytes)),
      ])
    guard case .object(let answer) = began, case .object(let result)? = answer["result"],
      case .string(let id)? = result["importId"]
    else { throw CocoaError(.coderInvalidValue) }
    _ = try await call(
      handler, "artifact.import.append",
      [
        "importId": .string(id), "generation": .string("1"), "offset": .string("0"),
        "byteCount": .string(String(bytes.count)),
        "sha256": .string(SHA256Hex.string(of: bytes)),
        "base64": .string(bytes.base64EncodedString()),
      ])
    let committed = try await call(
      handler, "artifact.import.commit", ["importId": .string(id), "generation": .string("1")])
    guard case .object(let done) = committed, case .object(let receipt)? = done["result"],
      case .object(let fields)? = receipt["receipt"], case .string(let lease)? = fields["lease"]
    else { throw CocoaError(.coderInvalidValue) }
    return lease
  }

  private func requestJSON(
    _ requestID: String, operation: RuntimeOperationReference,
    inputs: [String: JSONValue], revision: Int? = 1, capability: String? = nil
  ) throws -> String {
    let request = try RuntimeOperationRequest(
      requestID: requestID, idempotencyKey: "idem-\(requestID)",
      target: DurableTargetReference(targetID: target.targetID, expectedBindingRevision: revision),
      operation: operation, inputs: inputs,
      authorization: capability.map { RuntimeCapabilityReference(capabilityID: $0) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(request), as: UTF8.self)
  }

  /// Every regular file below `root`, relative to it, with its mode.
  private static func tree(_ root: URL) throws -> [(String, Data, Int)] {
    var result: [(String, Data, Int)] = []
    for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
      let url = root.appending(path: path)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
      guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
      result.append((path, try Data(contentsOf: url), Int(metadata.st_mode & 0o777)))
    }
    return result
  }

  /// Swift's Rockchip dispatcher as `main.swift` composes it, asked for the
  /// Flash provider. `records` names the state its record root
  /// (`<state>/rockchip-runtime`) is left in first; the reason is recorded,
  /// and whether an absent root was created owner-only.
  ///
  /// `records.privatePrefix` is an owner-only root below `/private`: Swift's
  /// canonical check standardizes an existing `/private/tmp/…` path to
  /// `/tmp/…` and refuses it, which the Rust Runtime declares it does not.
  private static func dispatcherReasons() throws -> [JSONValue] {
    let base = dispatchRoot
    let daemon = base.appending(path: "arkforged")
    let bytes = Data("#!/bin/sh\nexit 0\n".utf8)
    try bytes.write(to: daemon)
    guard chmod(daemon.path, 0o755) == 0 else { throw POSIXError(.EIO) }
    let configured = ArkForgeNativeRockUSBExecutableResolver(
      daemonPath: daemon.path, declaredSHA256: SHA256Hex.string(of: bytes))
    let hdc = FixedExecutableResolver(table: [
      "hdc": ResolvedExecutable(path: "/usr/bin/true", sha256: String(repeating: "e", count: 64))
    ])
    let cases: [(String, Bool, String?)] = [
      ("identity.unconfigured", false, nil),
      ("host.withoutHDC", true, nil),
      ("records.absent", true, "absent"),
      ("records.ownerOnly", true, "ownerOnly"),
      ("records.groupReadable", true, "groupReadable"),
      ("records.symlink", true, "symlink"),
      ("records.file", true, "file"),
      ("records.ownerOnlyFile", true, "ownerOnlyFile"),
      ("records.stateMissing", true, "stateMissing"),
      ("records.privatePrefix", true, "ownerOnly"),
    ]
    var recorded: [JSONValue] = []
    for (name, isConfigured, records) in cases {
      let resolver =
        isConfigured
        ? configured : ArkForgeNativeRockUSBExecutableResolver(daemonPath: nil, declaredSHA256: nil)
      let dispatcher: ArkForgeNativeRockchipControlDispatcher
      var recordRoot: URL?
      if let records {
        let state = (name == "records.privatePrefix" ? root : base)
          .appending(path: name, directoryHint: .isDirectory)
        if records != "stateMissing" {
          try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let root = state.appending(path: "rockchip-runtime", directoryHint: .isDirectory)
        switch records {
        case "ownerOnly", "groupReadable":
          try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: records == "ownerOnly" ? 0o700 : 0o750])
        case "symlink":
          let elsewhere = state.appending(path: "elsewhere", directoryHint: .isDirectory)
          try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          guard symlink(elsewhere.path, root.path) == 0 else { throw POSIXError(.EIO) }
        case "file", "ownerOnlyFile":
          try Data("not a directory".utf8).write(to: root)
          if records == "ownerOnlyFile" {
            guard chmod(root.path, 0o600) == 0 else { throw POSIXError(.EIO) }
          }
        default:
          break
        }
        dispatcher = ArkForgeNativeRockchipControlDispatcher(
          resolver: resolver, hdcResolver: hdc, stateDirectory: state,
          stateWorkingDirectory: state)
        recordRoot = root
      } else {
        dispatcher = ArkForgeNativeRockchipControlDispatcher(resolver: resolver)
      }
      let reason = dispatcher.unavailableReason(providerID: CatalogProvider.arkforge.rawValue)
      var createdMode: JSONValue = .null
      var metadata = stat()
      if records == "absent", let recordRoot, lstat(recordRoot.path, &metadata) == 0 {
        createdMode = .string(String(Int(metadata.st_mode & 0o7777), radix: 8))
      }
      recorded.append(
        .object([
          "name": .string(name), "identityConfigured": .bool(isConfigured),
          "records": records.map(JSONValue.string) ?? .null,
          "reason": reason.map(JSONValue.string) ?? .null,
          "createdMode": createdMode,
        ]))
    }
    return recorded
  }

  func testSwiftPlansEveryFlashRequestAsTheRustRuntimeReplays() async throws {
    let recording = ProcessInfo.processInfo.environment[Self.recordVariable] != nil
    let (lease, exchanges) =
      recording ? try await importedExchanges() : try checkedInExchanges()

    var recorded: [JSONValue] = []
    for (name, setup, json) in exchanges {
      let answer = try await call(try handler(setup), "job.plan", ["requestJson": .string(json)])
      recorded.append(
        .object([
          "name": .string(name), "setup": setup.recorded,
          "requestJson": .string(json), "answer": answer,
        ]))
    }

    var files: [String: Data] = [:]
    var inputs: [JSONValue] = []
    for (path, bytes, mode) in try Self.tree(Self.root.appending(path: "artifacts")) {
      // A payload's verification cache pins its inode's fingerprint. A payload
      // laid down again is a new inode, which Swift verifies again and whose
      // cache it rewrites; that cache is not an answer, so a replay compares
      // the recorded one.
      files["inputs/artifacts/\(path)"] =
        recording || !path.hasSuffix("/.payload-verification-v1.json")
        ? bytes
        : try Data(contentsOf: Self.oracle.appending(path: "inputs/artifacts/\(path)"))
      inputs.append(.object(["path": .string(path), "mode": .string(String(mode, radix: 8))]))
    }
    for (path, bytes, mode) in try Self.tree(Self.root.appending(path: "targets")) {
      files["inputs/targets/\(path)"] = bytes
      inputs.append(
        .object(["path": .string("../targets/\(path)"), "mode": .string(String(mode, radix: 8))]))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(
        JSONValue.object([
          "targetId": .string(target.targetID), "lease": .string(lease),
          "inputs": .array(inputs), "exchanges": .array(recorded),
        ])) + Data("\n".utf8)
    files["dispatch.json"] =
      try encoder.encode(JSONValue.array(try Self.dispatcherReasons())) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("FlashPlanOracleContractTests"),
          "root": .string(Self.root.path),
          "steps": .array([
            .string("artifact.import (flash-bundle, production policy)"),
            .string("RuntimeControlPlaneHandler job.plan"),
            .string("RuntimeJobEngine.planOnly"),
            .string("ArkForgeNativeRockchipControlDispatcher.unavailableReason (dispatch.json)"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  /// Compare mode: the checked-in Artifact root and Target store laid down,
  /// and the checked-in exchanges with their setups.
  private func checkedInExchanges() throws -> (String, [(String, Setup, String)]) {
    let cases = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "cases.json")))
    guard case .object(let fields) = cases, case .string(let targetID)? = fields["targetId"],
      case .string(let lease)? = fields["lease"], case .array(let inputs)? = fields["inputs"],
      case .array(let exchanges)? = fields["exchanges"]
    else { throw CocoaError(.coderInvalidValue) }
    for input in inputs {
      guard case .object(let entry) = input, case .string(let path)? = entry["path"],
        case .string(let mode)? = entry["mode"], let bits = Int(mode, radix: 8)
      else { throw CocoaError(.coderInvalidValue) }
      let source: URL
      let destination: URL
      if path.hasPrefix("../targets/") {
        let relative = String(path.dropFirst("../targets/".count))
        source = Self.oracle.appending(path: "inputs/targets/\(relative)")
        destination = Self.root.appending(path: "targets/\(relative)")
      } else {
        source = Self.oracle.appending(path: "inputs/artifacts/\(path)")
        destination = Self.root.appending(path: "artifacts/\(path)")
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Data(contentsOf: source).write(to: destination)
      guard chmod(destination.path, mode_t(bits)) == 0 else { throw POSIXError(.EIO) }
    }
    try openStores()
    guard let found = try targets.find(targetID: targetID) else {
      throw CocoaError(.coderValueNotFound)
    }
    target = found
    return (
      lease,
      try exchanges.map { exchange in
        guard case .object(let entry) = exchange, case .string(let name)? = entry["name"],
          let setup = entry["setup"], case .string(let json)? = entry["requestJson"]
        else { throw CocoaError(.coderInvalidValue) }
        return (name, try Setup(recorded: setup), json)
      }
    )
  }

  /// Record mode: the board adopted and its bundle imported now, and every
  /// exchange this oracle plans.
  private func importedExchanges() async throws -> (String, [(String, Setup, String)]) {
    try openStores()
    target = try targets.adopt(
      stableIdentitySHA256: Self.digest(Self.connectKey), connectKey: Self.connectKey,
      toolVersion: "3.2.0f", nowUTC: Self.nowUTC
    ).record
    let lease = try await importBundle("flash-plan-bundle", archive: "complete.tar.gz")
    let canonical = try RuntimeOperationReference(id: "flash.full-restore", version: 1)
    let alias = try RuntimeOperationReference(id: "flash.dayu200")
    let full: [String: JSONValue] = [
      "artifactLease": .string(lease), "deviceProfileRef": .string("dayu200"),
      "intent": .string("fullRestore"), "verification": .string("full"),
    ]
    var basic = full
    basic["verification"] = .string("basic")
    let partitions: [JSONValue] = RockchipFlashProfile.dayu200.mappedPartitions
      .map { .string($0.partitionName) }
    let legacy: [String: JSONValue] = [
      "imageBundleLease": .string(lease), "deviceProfile": .string("dayu200"),
      "partitionPlan": .array(partitions), "postFlashVerification": .string("full"),
    ]
    var legacyBasic = legacy
    legacyBasic["postFlashVerification"] = .string("basic")
    var legacyDefault = legacy
    legacyDefault.removeValue(forKey: "postFlashVerification")
    var reordered = legacy
    reordered["partitionPlan"] = .array(partitions.reversed())
    var shortPlan = legacy
    shortPlan["partitionPlan"] = .array(Array(partitions.dropLast()))
    var unknownLease = full
    unknownLease["artifactLease"] = .string(
      "lease-v1:imp-00000000-0000-4000-8000-000000000000:ART-0123456789abcdef0123456789abcdef")

    var exchanges: [(String, Setup, String)] = [
      ("canonical.full", Setup(), try requestJSON("canonical-full", operation: canonical, inputs: full)),
      ("canonical.basic", Setup(), try requestJSON("canonical-basic", operation: canonical, inputs: basic)),
      ("alias.full", Setup(), try requestJSON("alias-full", operation: alias, inputs: legacy)),
      ("alias.basic", Setup(), try requestJSON("alias-basic", operation: alias, inputs: legacyBasic)),
      ("alias.defaultVerification", Setup(),
       try requestJSON("alias-default", operation: alias, inputs: legacyDefault)),
      ("alias.reorderedPlan", Setup(),
       try requestJSON("alias-reordered", operation: alias, inputs: reordered)),
      ("alias.shortPlan", Setup(), try requestJSON("alias-short", operation: alias, inputs: shortPlan)),
      ("availability.notRegistered",
       Setup(unavailable: "production ArkForge Flash lane is not registered"),
       try requestJSON("not-registered", operation: canonical, inputs: full)),
      ("availability.hardwareGated",
       Setup(
         unavailable:
           "ArkForge is connected for assessment only (hardwareGated). Flash is unavailable: "
           + "this configuration has no reviewed production support record or named hardware "
           + "acceptance campaign."),
       try requestJSON("hardware-gated", operation: alias, inputs: legacy)),
      ("dispatcher.unavailable",
       Setup(
         dispatchUnavailable:
           "ArkForge native RockUSB identity is unavailable: failed(\"ArkForge native RockUSB "
           + "lane is not configured\")"),
       try requestJSON("dispatcher", operation: canonical, inputs: full)),
      ("lane.absent", Setup(toolchain: nil), try requestJSON("no-lane", operation: canonical, inputs: full)),
      ("facts.error",
       Setup(factsError: "production ArkForge target facts are not registered"),
       try requestJSON("facts-error", operation: canonical, inputs: full)),
      ("facts.staleRevision", Setup(facts: Self.facts(bindingRevision: 2)),
       try requestJSON("facts-stale", operation: canonical, inputs: full)),
      ("facts.emptyConnectKey", Setup(facts: Self.facts(connectKey: "")),
       try requestJSON("facts-empty-key", operation: canonical, inputs: full)),
      ("facts.identityNotDigest", Setup(facts: Self.facts(identity: "NOT-A-DIGEST")),
       try requestJSON("facts-identity", operation: canonical, inputs: full)),
      ("facts.toolNotDigest", Setup(facts: Self.facts(tool: "arkforged")),
       try requestJSON("facts-tool", operation: canonical, inputs: full)),
      ("facts.crossModeUnprepared", Setup(facts: Self.facts(crossMode: "unprepared")),
       try requestJSON("cross-mode", operation: canonical, inputs: full)),
      ("facts.noAlias", Setup(facts: Self.facts(aliasTopology: nil)),
       try requestJSON("no-alias", operation: canonical, inputs: full)),
      ("facts.aliasIdentityMismatch",
       Setup(facts: Self.facts(aliasIdentity: String(repeating: "d", count: 64))),
       try requestJSON("alias-mismatch", operation: canonical, inputs: full)),
      ("lease.unknown", Setup(), try requestJSON("unknown-lease", operation: canonical, inputs: unknownLease)),
      ("request.capability", Setup(),
       try requestJSON("capability", operation: canonical, inputs: full, capability: "CAP-RT-X")),
      ("request.noRevision", Setup(),
       try requestJSON("no-revision", operation: canonical, inputs: full, revision: nil)),
    ]
    // A bundle bound to another Target, imported last so every other exchange
    // reads one Import.
    let other = try targets.adopt(
      stableIdentitySHA256: Self.digest("another-board"), connectKey: "another-board",
      toolVersion: "3.2.0f", nowUTC: Self.nowUTC
    ).record
    let saved = target
    target = other
    let otherLease = try await importBundle("flash-plan-other", archive: "complete.tar.gz")
    target = saved
    var foreign = full
    foreign["artifactLease"] = .string(otherLease)
    exchanges.append(
      ("lease.otherTarget", Setup(), try requestJSON("other-target", operation: canonical, inputs: foreign)))
    return (lease, exchanges)
  }
}
