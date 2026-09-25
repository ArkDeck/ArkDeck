// Shared Swift oracle for the Rust Runtime's Flash recovery broker:
// `debug.start` and `debug.evaluate` (CHG-2026-074, TASK-XPA-017, milestone
// M4).

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

/// Swift's `RuntimeDebugInvocationController`, as the daemon composes it
/// (`RuntimeJobEngineDebugAttemptDriver` over the engine's `planOnly`),
/// through the daemon's control-plane handler: `debug.start`,
/// `debug.evaluate` and, to read the documents they leave, `debug.status`.
///
/// A flash bundle is imported first, through the same handler with the
/// production policy; every seed request names its lease. Each exchange then
/// composes the engine as its setup names it — the provider's availability,
/// the dispatcher's reason, the lane's toolchain, the facts port's answer —
/// over one controller state directory, at the clock reading it names.
///
/// Four documents are laid down before the exchanges, written by the same
/// controller over a scripted driver: one blocked by a known failure, one
/// succeeded, one whose sixteen destructive epochs are spent, and one whose
/// last attempt was interrupted while executing. They are the states an
/// evaluation refuses before anything is planned.
///
/// An invocation the broker mints is named at random. Each is read as
/// `<invocation-N>`, in order of its start, in every answer and in the
/// documents, and its last twelve characters, which an attempt's request
/// identity carries, as `<invocation-N-suffix>`; a request naming one names
/// its label. A Job the engine admits is read as `<job>`.
///
/// `executePinnedRequest` is recorded apart (`execute.json`): Swift admits it
/// through the engine, which the Rust Runtime declares it does not do.
///
/// No device, ArkForge daemon, HDC or dispatch is involved.
///
/// Record a new oracle with
/// `ARKDECK_RUST_DEBUG_INVOCATION_RECORD=/private/tmp/<new directory>`.
/// Otherwise nothing is imported or minted by the setup: the checked-in
/// inputs are laid down, every recorded exchange is sent again, and the
/// answers and the documents left must match byte for byte.
final class DebugInvocationOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/debug-invocation", directoryHint: .isDirectory)
  private static let archives = repository.appending(
    path: "rust/tests/fixtures/flash-archive/archives", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_DEBUG_INVOCATION_RECORD"
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-debug-invocation-oracle", directoryHint: .isDirectory)
  private static let state = root.appending(path: "state", directoryHint: .isDirectory)
  private static let invocations = "runtime-debug-invocations"
  private static let startedAt = "2026-09-25T00:00:00Z"
  private static let connectKey = "150100424a544e4600"
  private static let aliasKey = "post-flash-hdc-address"
  private static let toolchain = String(repeating: "c", count: 64)
  private static let arkforged = String(repeating: "b", count: 64)
  private static let hardwareGated =
    "ArkForge is connected for assessment only (hardwareGated). Flash is unavailable: "
    + "this configuration has no reviewed production support record or named hardware "
    + "acceptance campaign."

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// A lane that only names the toolchain its StepPermits bind.
  private actor Lane: RuntimeJobEngine.ArkForgeLane {
    nonisolated let toolchainSHA256: String

    init(toolchainSHA256: String) { self.toolchainSHA256 = toolchainSHA256 }

    func prepareExecution(
      jobID _: String, artifact _: ArkForgeLaneArtifact,
      binding _: ArkForgeLaneDeviceBinding, executionPurpose _: String
    ) async throws -> RuntimeArkForgeLaneExecution {
      throw RuntimeDispatchFailure.failed("the oracle never prepares an execution")
    }

    func performPrepared(
      stepID: String, execution _: RuntimeArkForgeLaneExecution,
      artifact _: ArkForgeLaneArtifact, binding _: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary {
      throw RuntimeDispatchFailure.failed("the oracle never performs \(stepID)")
    }

    func observeTerminal(
      execution _: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome? {
      throw RuntimeDispatchFailure.failed("the oracle never observes an execution")
    }

    func completedPlanReceipt(jobID _: String) async -> ArkForgeActionReceiptSummary? { nil }
  }

  private struct Dispatcher: RuntimeProcessDispatching {
    let reason: String?

    func unavailableReason(providerID _: String) -> String? { reason }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      throw RuntimeDispatchFailure.failed("the oracle never dispatches")
    }
  }

  private struct Facts: RockchipRuntimeFactsPort {
    let answer: Result<ProviderFacts, DeviceProviderError>

    func currentFacts(targetID _: String) async throws -> ProviderFacts {
      try answer.get()
    }
  }

  /// Stands in for the engine only to write the documents laid down before
  /// the exchanges: each execution's outcome from a script.
  private actor ScriptedDriver: RuntimeDebugAttemptDriving {
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
        stableIdentitySHA256: DebugInvocationOracleContractTests.digest(
          DebugInvocationOracleContractTests.connectKey),
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

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }
    func now() -> String { lock.withLock { value } }
    func set(_ value: String) { lock.withLock { self.value = value } }
  }

  /// What one exchange's engine reads besides the bundle, and when.
  private struct Setup {
    var unavailable: String? = nil
    var dispatchUnavailable: String? = nil
    var toolchain: String? = DebugInvocationOracleContractTests.toolchain
    var facts: [String: JSONValue]? = DebugInvocationOracleContractTests.facts()
    var factsError: String? = nil
    var now: String = DebugInvocationOracleContractTests.startedAt

    init(
      unavailable: String? = nil, dispatchUnavailable: String? = nil,
      toolchain: String? = DebugInvocationOracleContractTests.toolchain,
      facts: [String: JSONValue]? = DebugInvocationOracleContractTests.facts(),
      factsError: String? = nil, now: String = DebugInvocationOracleContractTests.startedAt
    ) {
      self.unavailable = unavailable
      self.dispatchUnavailable = dispatchUnavailable
      self.toolchain = toolchain
      self.facts = facts
      self.factsError = factsError
      self.now = now
    }

    init(recorded: JSONValue) throws {
      guard case .object(let fields) = recorded else { throw CocoaError(.coderInvalidValue) }
      func text(_ key: String) -> String? {
        if case .string(let value)? = fields[key] { return value }
        return nil
      }
      unavailable = text("unavailable")
      dispatchUnavailable = text("dispatchUnavailable")
      toolchain = text("toolchainSha256")
      guard let now = text("now") else { throw CocoaError(.coderInvalidValue) }
      self.now = now
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
        "now": .string(now),
      ])
    }
  }

  /// The facts a covered, post-flash-routed DAYU200 answers with.
  private static func facts(
    bindingRevision: Int = 1, crossMode: String = "satisfied"
  ) -> [String: JSONValue] {
    [
      "bindingRevision": .integer(Int64(bindingRevision)),
      "executionConnectKey": .string(aliasKey),
      "deviceIdentitySha256": .string(digest(connectKey)),
      "toolSha256": .string(arkforged),
      "serverFacts": .object([
        "rockusbBackend": .string("native"),
        "arkForgeToolchainID": .string(ArkForgeNativeRockUSBToolchain.identifier),
        "dayu200CrossModeBinding": .string(crossMode),
        "dayu200HDCNormalAliasSHA256": .string(digest(aliasKey)),
        "dayu200HDCNormalAliasUSBTopology": .string("42"),
      ]),
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
      profileID: "dayu200", collectedAtUTC: startedAt)
  }

  private var targets: RuntimeTargetStore!
  private var artifacts: RuntimeArtifactStore!
  private var target: RuntimeTargetRecord!
  private var engineCount = 0
  private let clock = Clock(DebugInvocationOracleContractTests.startedAt)

  override func setUpWithError() throws {
    try? FileManager.default.removeItem(at: Self.root)
    try FileManager.default.createDirectory(
      at: Self.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    artifacts = nil; targets = nil
    try? FileManager.default.removeItem(at: Self.root)
  }

  private func openStores() throws {
    targets = try RuntimeTargetStore(directoryURL: Self.root.appending(path: "targets"))
    artifacts = try RuntimeArtifactStore(
      rootURL: Self.root.appending(path: "artifacts"), nowUTC: { DebugInvocationOracleContractTests.startedAt })
  }

  /// `shared` composes the engine over the broker's own state directory, as
  /// the daemon does; the exchanges' engines each have their own, so that
  /// only the broker's documents are compared.
  private func engine(
    _ setup: Setup, shared: Bool = false
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore) {
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
        stateDirectory: shared
          ? Self.state : Self.root.appending(path: "engines/\(engineCount)/state"),
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
      capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { DebugInvocationOracleContractTests.startedAt })
    return (engine, capabilities)
  }

  /// The daemon's handler over an engine composed as `setup` names it and
  /// the broker over the one controller state directory.
  private func handler(
    _ setup: Setup, shared: Bool = false
  ) throws -> RuntimeControlPlaneHandler {
    let (engine, capabilities) = try engine(setup, shared: shared)
    clock.set(setup.now)
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: Self.state, driver: RuntimeJobEngineDebugAttemptDriver(engine: engine),
      nowUTC: clock.now)
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: ["arkforge"],
      nowUTC: { DebugInvocationOracleContractTests.startedAt }, targetStore: targets,
      bootstrap: nil, artifactStore: artifacts, flashBundleImportDirectory: nil,
      flashBundleImportPolicy: .production, debugInvocationController: controller,
      methodObserver: nil)
  }

  private func call(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let request = try ArkDeckAgentXPC.requestFrame(
      method: method, params: params, requestID: "debug-invocation")
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

  /// Imports the complete synthetic archive for the board and answers its
  /// lease.
  private func importBundle() async throws -> String {
    let bytes = try Data(contentsOf: Self.archives.appending(path: "complete.tar.gz"))
    let handler = try handler(Setup())
    let began = try await call(
      handler, "artifact.import.begin",
      [
        "schemaVersion": .string(ArtifactImportIntent.schemaVersion),
        "importRequestId": .string("debug-invocation-bundle"), "kind": .string("flash-bundle"),
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

  private func seed(
    _ requestID: String, operation: RuntimeOperationReference, inputs: [String: JSONValue],
    revision: Int? = 1
  ) throws -> String {
    let request = try RuntimeOperationRequest(
      requestID: requestID, idempotencyKey: "idem-\(requestID)",
      target: DurableTargetReference(targetID: target.targetID, expectedBindingRevision: revision),
      operation: operation, inputs: inputs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(request), as: UTF8.self)
  }

  /// Every regular file below `root`, relative to it, with its mode.
  private static func tree(_ root: URL) throws -> [(String, Data, Int)] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
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

  // MARK: - The documents laid down before the exchanges

  /// Writes the four documents an evaluation refuses before it plans, by
  /// label, through the controller over a scripted driver.
  private func layDownDocuments(seed: String) async throws -> [String: String] {
    let driver = ScriptedDriver()
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: Self.state, driver: driver, nowUTC: clock.now)
    let execute = Data(#"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#.utf8)
    func provenance(_ ordinal: Int) throws -> RuntimeDebugCandidateProvenance {
      try RuntimeDebugCandidateProvenance(
        sourceSHA256: String(format: "%064x", ordinal),
        buildSHA256: String(format: "%064x", ordinal + 100))
    }
    var identities: [String: String] = [:]
    for (label, outcomes) in [
      ("blocked", [RuntimeDebugExecutionOutcome.failedKnown]),
      ("succeeded", [.succeeded]),
      ("exhausted", Array(repeating: .safeToReflash, count: 16)),
      ("interrupted", [.outcomeUnknown]),
    ] {
      clock.set("2026-09-24T23:00:00Z")
      let status = try await controller.start(seedRequestData: Data(seed.utf8))
      identities[label] = status.invocationID
      await driver.script(outcomes)
      for (index, _) in outcomes.enumerated() {
        clock.set(String(format: "2026-09-24T23:%02d:00Z", index + 1))
        _ = try await controller.evaluate(
          invocationID: status.invocationID, actionData: execute,
          provenance: try provenance(index + 1))
      }
    }
    // An attempt interrupted while executing: the last evaluation as the
    // controller persisted it before it called the driver.
    let url = Self.state.appending(path: "\(Self.invocations)/\(identities["interrupted"]!).json")
    guard case .object(var document) = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: url)),
      case .array(var evaluations)? = document["evaluations"],
      case .object(var last)? = evaluations.last
    else { throw CocoaError(.coderInvalidValue) }
    last.removeValue(forKey: "outcome")
    last.removeValue(forKey: "jobID")
    last["disposition"] = .string("executing")
    last["detail"] = .string("Runtime attempt durably prepared")
    evaluations[evaluations.count - 1] = .object(last)
    document["evaluations"] = .array(evaluations)
    try DurableFileWriter.createOrReplaceAtomically(
      destination: url,
      data: try RuntimeDebugAttemptPermitStore.canonicalEncode(JSONValue.object(document)))
    return identities
  }

  // MARK: - The exchanges

  private struct Exchange {
    let name: String
    let setup: Setup
    let method: String
    let params: [String: JSONValue]
  }

  private static let observe = #"{"schemaVersion":"1.0.0","action":"observePinnedRequest"}"#
  private static let execute = #"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#

  private static func evaluate(
    _ invocation: String, _ action: String, source: Int = 1, build: Int = 101
  ) -> [String: JSONValue] {
    [
      "invocationId": .string(invocation), "actionJson": .string(action),
      "sourceSha256": .string(String(format: "%064x", source)),
      "buildSha256": .string(String(format: "%064x", build)),
    ]
  }

  private func exchanges(
    lease: String, documents: [String: String]
  ) throws -> [Exchange] {
    let canonical = try RuntimeOperationReference(id: "flash.full-restore", version: 1)
    let alias = try RuntimeOperationReference(id: "flash.dayu200")
    let full: [String: JSONValue] = [
      "artifactLease": .string(lease), "deviceProfileRef": .string("dayu200"),
      "intent": .string("fullRestore"), "verification": .string("full"),
    ]
    let partitions: [JSONValue] = RockchipFlashProfile.dayu200.mappedPartitions
      .map { .string($0.partitionName) }
    let legacy: [String: JSONValue] = [
      "imageBundleLease": .string(lease), "deviceProfile": .string("dayu200"),
      "partitionPlan": .array(partitions), "postFlashVerification": .string("full"),
    ]
    var reordered = legacy
    reordered["partitionPlan"] = .array(partitions.reversed())
    let seedA = try seed("seed-a", operation: canonical, inputs: full)
    func start(_ json: String) -> [String: JSONValue] { ["requestJson": .string(json)] }
    var withAuthorization = try JSONDecoder().decode(JSONValue.self, from: Data(seedA.utf8))
    var withClient = withAuthorization
    if case .object(var object) = withAuthorization {
      object["authorization"] = .object(["capabilityId": .string("CAP-RT-X")])
      withAuthorization = .object(object)
    }
    if case .object(var object) = withClient {
      object["clientContext"] = .object(["clientName": .string("ArkDeckApp.FlashWorkspace")])
      withClient = .object(object)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func json(_ value: JSONValue) throws -> String {
      String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    let unknown = seedA.replacingOccurrences(
      of: #""id":"flash.full-restore""#, with: #""id":"flash.nothing""#)
    let governance = String(seedA.dropLast()) + #","trustedFacts":{}}"#
    let observeDevice = try seed(
      "seed-observe", operation: try RuntimeOperationReference(id: "observe.device", version: 1),
      inputs: [:])
    let later = "2026-09-25T00:30:00Z"
    // `<invocation-3>` was started at 00:00:10 and expires four hours later.
    let past = "2026-09-25T04:00:11Z"
    var list: [Exchange] = [
      Exchange(name: "start.params.extra", setup: Setup(), method: "debug.start",
               params: ["requestJson": .string(seedA), "extra": .bool(true)]),
      Exchange(name: "start.params.none", setup: Setup(), method: "debug.start", params: [:]),
      Exchange(name: "start.params.notText", setup: Setup(), method: "debug.start",
               params: ["requestJson": .integer(1)]),
      Exchange(name: "start.seed.malformed", setup: Setup(), method: "debug.start",
               params: start("{\"requestId\":")),
      Exchange(name: "start.seed.duplicate", setup: Setup(), method: "debug.start",
               params: start(String(seedA.dropLast()) + #","requestId":"again"}"#)),
      Exchange(name: "start.seed.governance", setup: Setup(), method: "debug.start",
               params: start(governance)),
      Exchange(name: "start.seed.authorization", setup: Setup(), method: "debug.start",
               params: start(try json(withAuthorization))),
      Exchange(name: "start.seed.client", setup: Setup(), method: "debug.start",
               params: start(try json(withClient))),
      Exchange(name: "start.plan.unknownOperation", setup: Setup(), method: "debug.start",
               params: start(unknown)),
      Exchange(name: "start.plan.hardwareGated", setup: Setup(unavailable: Self.hardwareGated),
               method: "debug.start", params: start(seedA)),
      Exchange(name: "start.plan.aliasNotConvertible", setup: Setup(), method: "debug.start",
               params: start(try seed("seed-reordered", operation: alias, inputs: reordered))),
      Exchange(name: "start.plan.noRevision", setup: Setup(), method: "debug.start",
               params: start(try seed("seed-no-revision", operation: canonical, inputs: full,
                                      revision: nil))),
      Exchange(name: "start.plan.otherProvider", setup: Setup(), method: "debug.start",
               params: start(observeDevice)),
      Exchange(name: "start.canonical", setup: Setup(), method: "debug.start",
               params: start(seedA)),
      Exchange(name: "start.alias", setup: Setup(now: "2026-09-25T00:00:05Z"),
               method: "debug.start",
               params: start(try seed("seed-b", operation: alias, inputs: legacy))),
      Exchange(name: "start.expiring", setup: Setup(now: "2026-09-25T00:00:10Z"),
               method: "debug.start",
               params: start(try seed("seed-c", operation: canonical, inputs: full))),
      Exchange(name: "start.executing", setup: Setup(now: "2026-09-25T00:00:15Z"),
               method: "debug.start",
               params: start(try seed("seed-d", operation: canonical, inputs: full))),
      Exchange(name: "evaluate.params.missing", setup: Setup(), method: "debug.evaluate",
               params: ["invocationId": .string("<invocation-1>"),
                        "actionJson": .string(Self.observe)]),
      Exchange(name: "evaluate.params.notText", setup: Setup(), method: "debug.evaluate",
               params: ["invocationId": .string("<invocation-1>"), "actionJson": .integer(1),
                        "sourceSha256": .string(String(format: "%064x", 1)),
                        "buildSha256": .string(String(format: "%064x", 101))]),
      Exchange(name: "evaluate.provenance.uppercase", setup: Setup(), method: "debug.evaluate",
               params: ["invocationId": .string("<invocation-1>"),
                        "actionJson": .string(Self.observe),
                        "sourceSha256": .string(String(repeating: "A", count: 64)),
                        "buildSha256": .string(String(format: "%064x", 101))]),
      Exchange(name: "evaluate.provenance.short", setup: Setup(), method: "debug.evaluate",
               params: ["invocationId": .string("<invocation-1>"),
                        "actionJson": .string(Self.observe),
                        "sourceSha256": .string(String(format: "%064x", 1)),
                        "buildSha256": .string("abc")]),
      Exchange(name: "evaluate.invocation.unknown", setup: Setup(), method: "debug.evaluate",
               params: Self.evaluate("debug-00000000-0000-4000-8000-000000000000", Self.observe)),
      Exchange(name: "evaluate.invocation.invalid", setup: Setup(), method: "debug.evaluate",
               params: Self.evaluate("Debug!", Self.observe)),
    ]
    let actions: [(String, String)] = [
      ("empty", ""),
      ("emptyObject", "{}"),
      ("array", "[]"),
      ("notJSON", "observe"),
      ("trailing", Self.observe + " x"),
      ("duplicate", #"{"schemaVersion":"1.0.0","action":"stop","action":"stop"}"#),
      ("tooLarge", #"{"schemaVersion":"1.0.0","action":"observePinnedRequest","pad":""#
        + String(repeating: "x", count: 8_200) + "\"}"),
      ("schemaVersion", #"{"schemaVersion":"2.0.0","action":"observePinnedRequest"}"#),
      ("schemaVersionNumber", #"{"schemaVersion":1,"action":"observePinnedRequest"}"#),
      ("noAction", #"{"schemaVersion":"1.0.0"}"#),
      ("actionNumber", #"{"schemaVersion":"1.0.0","action":7}"#),
      ("unknownAction", #"{"schemaVersion":"1.0.0","action":"reboot"}"#),
      ("observeExtra", #"{"schemaVersion":"1.0.0","action":"observePinnedRequest","x":1}"#),
      ("executeExtra", #"{"schemaVersion":"1.0.0","action":"executePinnedRequest","x":1}"#),
      ("stopNoReason", #"{"schemaVersion":"1.0.0","action":"stop"}"#),
      ("stopReasonNumber", #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":1}"#),
      ("stopReasonUpper", #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"Stop"}"#),
      ("stopReasonSpace", #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"a b"}"#),
      ("stopReasonEmpty", #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":""}"#),
      ("stopReasonLong",
        #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"a"#
        + String(repeating: "b", count: 128) + "\"}"),
      ("stopReasonTwoNewlines",
        #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"ok\n\n"}"#),
      ("stopReasonNewlineInside",
        #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"o\nk"}"#),
    ]
    for (name, action) in actions {
      list.append(
        Exchange(name: "evaluate.action.\(name)", setup: Setup(), method: "debug.evaluate",
                 params: Self.evaluate("<invocation-1>", action)))
    }
    list += [
      Exchange(name: "evaluate.observe", setup: Setup(now: "2026-09-25T00:10:00Z"),
               method: "debug.evaluate", params: Self.evaluate("<invocation-1>", Self.observe)),
      Exchange(name: "evaluate.observe.blocker",
               setup: Setup(facts: Self.facts(crossMode: "unprepared"),
                            now: "2026-09-25T00:11:00Z"),
               method: "debug.evaluate",
               params: Self.evaluate("<invocation-1>", Self.observe, source: 2, build: 102)),
      Exchange(name: "evaluate.observe.hardwareGated",
               setup: Setup(unavailable: Self.hardwareGated, now: "2026-09-25T00:12:00Z"),
               method: "debug.evaluate", params: Self.evaluate("<invocation-1>", Self.observe)),
      Exchange(name: "evaluate.observe.factsError",
               setup: Setup(factsError: "production ArkForge target facts are not registered",
                            now: "2026-09-25T00:12:30Z"),
               method: "debug.evaluate", params: Self.evaluate("<invocation-1>", Self.observe)),
      Exchange(name: "evaluate.observe.alias", setup: Setup(now: "2026-09-25T00:13:00Z"),
               method: "debug.evaluate", params: Self.evaluate("<invocation-2>", Self.observe)),
      Exchange(name: "evaluate.stop", setup: Setup(now: later), method: "debug.evaluate",
               params: Self.evaluate(
                 "<invocation-1>",
                 #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"operator.cancelled"}"#,
                 source: 3, build: 103)),
      Exchange(name: "evaluate.afterStop", setup: Setup(now: later), method: "debug.evaluate",
               params: Self.evaluate("<invocation-1>", Self.observe)),
      Exchange(name: "evaluate.stop.trailingNewline", setup: Setup(now: later),
               method: "debug.evaluate",
               params: Self.evaluate(
                 "<invocation-2>",
                 #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"ok\n"}"#)),
      Exchange(name: "evaluate.expired", setup: Setup(now: past), method: "debug.evaluate",
               params: Self.evaluate("<invocation-3>", Self.observe)),
      Exchange(name: "evaluate.afterExpiry", setup: Setup(now: past), method: "debug.evaluate",
               params: Self.evaluate("<invocation-3>", Self.execute)),
      Exchange(name: "evaluate.blocked", setup: Setup(), method: "debug.evaluate",
               params: Self.evaluate(documents["blocked"]!, Self.observe)),
      Exchange(name: "evaluate.succeeded", setup: Setup(), method: "debug.evaluate",
               params: Self.evaluate(documents["succeeded"]!, Self.execute)),
      Exchange(name: "evaluate.exhausted", setup: Setup(), method: "debug.evaluate",
               params: Self.evaluate(documents["exhausted"]!, Self.execute)),
      Exchange(name: "evaluate.interrupted.otherCandidate", setup: Setup(),
               method: "debug.evaluate",
               params: Self.evaluate(documents["interrupted"]!, Self.execute, source: 9)),
      Exchange(name: "evaluate.interrupted.otherAction", setup: Setup(),
               method: "debug.evaluate",
               params: Self.evaluate(documents["interrupted"]!, Self.observe)),
    ]
    for label in ["<invocation-1>", "<invocation-2>", "<invocation-3>", "<invocation-4>"] {
      list.append(
        Exchange(name: "status.\(label.dropFirst().dropLast())", setup: Setup(),
                 method: "debug.status", params: ["invocationId": .string(label)]))
    }
    for (label, identity) in documents.sorted(by: { $0.key < $1.key }) {
      list.append(
        Exchange(name: "status.\(label)", setup: Setup(), method: "debug.status",
                 params: ["invocationId": .string(identity)]))
    }
    return list
  }

  // MARK: - Labels for the invocations the broker mints

  private final class Labels {
    private(set) var minted: [(String, String)] = []

    func name(_ method: String, _ answer: JSONValue) {
      guard method == "debug.start",
        case .object(let object) = answer, case .object(let result)? = object["result"],
        case .string(let identity)? = result["invocationID"],
        !minted.contains(where: { $0.0 == identity })
      else { return }
      minted.append((identity, "<invocation-\(minted.count + 1)>"))
    }

    func label(_ text: String) -> String {
      let named = minted.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
      let suffixed = minted.reduce(named) {
        $0.replacingOccurrences(
          of: String($1.0.suffix(12)), with: String($1.1.dropLast()) + "-suffix>")
      }
      return suffixed.replacingOccurrences(
        of: #"job-[0-9a-f]{32}"#, with: "<job>", options: .regularExpression)
    }

    func resolve(_ params: [String: JSONValue]) -> [String: JSONValue] {
      params.mapValues { value in
        guard case .string(let text) = value else { return value }
        return .string(minted.reduce(text) { $0.replacingOccurrences(of: $1.1, with: $1.0) })
      }
    }
  }

  private static func encode(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  // MARK: - The oracle

  func testSwiftBrokersEveryFlashInvocationAsTheRustRuntimeReplays() async throws {
    let recording = ProcessInfo.processInfo.environment[Self.recordVariable] != nil
    var files: [String: Data] = [:]
    let lease: String
    let documents: [String: String]
    var exchanges: [Exchange]
    if recording {
      try openStores()
      target = try targets.adopt(
        stableIdentitySHA256: Self.digest(Self.connectKey), connectKey: Self.connectKey,
        toolVersion: "3.2.0f", nowUTC: Self.startedAt
      ).record
      lease = try await importBundle()
      let canonical = try RuntimeOperationReference(id: "flash.full-restore", version: 1)
      documents = try await layDownDocuments(
        seed: try seed(
          "seed-laid-down", operation: canonical,
          inputs: [
            "artifactLease": .string(lease), "deviceProfileRef": .string("dayu200"),
            "intent": .string("fullRestore"), "verification": .string("full"),
          ]))
      exchanges = try self.exchanges(lease: lease, documents: documents)
    } else {
      (lease, documents, exchanges) = try checkedIn()
    }
    // What the exchanges start from: the Artifact root and Target store the
    // Import left, and the documents laid down.
    var inputs: [JSONValue] = []
    for (directory, prefix) in [("artifacts", "artifacts"), ("targets", "targets"),
                                ("state/\(Self.invocations)", Self.invocations)] {
      for (path, bytes, mode) in try Self.tree(Self.root.appending(path: directory)) {
        files["inputs/\(prefix)/\(path)"] =
          recording || !path.hasSuffix("/.payload-verification-v1.json")
          ? bytes
          : try Data(contentsOf: Self.oracle.appending(path: "inputs/\(prefix)/\(path)"))
        inputs.append(
          .object(["path": .string("\(prefix)/\(path)"),
                   "mode": .string(String(mode, radix: 8))]))
      }
    }

    let labels = Labels()
    var recorded: [JSONValue] = []
    for exchange in exchanges {
      let answer = try await call(
        try handler(exchange.setup), exchange.method, labels.resolve(exchange.params))
      labels.name(exchange.method, answer)
      recorded.append(
        .object([
          "name": .string(exchange.name), "setup": exchange.setup.recorded,
          "method": .string(exchange.method), "params": .object(exchange.params),
          "answer": try JSONDecoder().decode(
            JSONValue.self, from: Data(labels.label(try Self.encode(answer)).utf8)),
        ]))
    }
    // The documents the exchanges leave, each minted identity read as its
    // label.
    var left: [(String, JSONValue)] = []
    for (path, bytes, mode) in try Self.tree(Self.state.appending(path: Self.invocations)) {
      let labelled = labels.label(path)
      left.append(
        (
          labelled,
          .object([
            "path": .string(labelled), "mode": .string(String(mode, radix: 8)),
            "document": .string(labels.label(String(decoding: bytes, as: UTF8.self))),
          ])
        ))
    }

    // `executePinnedRequest` on its own invocation, after everything else.
    let executed = try await call(
      try handler(Setup(now: "2026-09-25T00:40:00Z"), shared: true), "debug.evaluate",
      labels.resolve(Self.evaluate("<invocation-4>", Self.execute)))
    let execute: JSONValue = .object([
      "setup": Setup(now: "2026-09-25T00:40:00Z").recorded,
      "params": .object(Self.evaluate("<invocation-4>", Self.execute)),
      "answer": try JSONDecoder().decode(
        JSONValue.self, from: Data(labels.label(try Self.encode(executed)).utf8)),
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(
        JSONValue.object([
          "targetId": .string(target.targetID), "lease": .string(lease),
          "documents": .object(documents.mapValues(JSONValue.string)),
          "inputs": .array(inputs), "exchanges": .array(recorded),
          "left": .array(left.sorted { $0.0 < $1.0 }.map(\.1)),
        ])) + Data("\n".utf8)
    files["execute.json"] = try encoder.encode(execute) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("DebugInvocationOracleContractTests"),
          "root": .string(Self.root.path),
          "steps": .array([
            .string("artifact.import (flash-bundle, production policy)"),
            .string("RuntimeDebugInvocationController over a scripted driver (documents laid down)"),
            .string("RuntimeControlPlaneHandler debug.start, debug.evaluate, debug.status"),
            .string("RuntimeJobEngineDebugAttemptDriver over RuntimeJobEngine.planOnly"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  /// Compare mode: the checked-in inputs laid down, and the checked-in
  /// exchanges with their setups.
  private func checkedIn() throws -> (String, [String: String], [Exchange]) {
    let cases = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "cases.json")))
    guard case .object(let fields) = cases, case .string(let targetID)? = fields["targetId"],
      case .string(let lease)? = fields["lease"], case .object(let named)? = fields["documents"],
      case .array(let inputs)? = fields["inputs"],
      case .array(let recorded)? = fields["exchanges"]
    else { throw CocoaError(.coderInvalidValue) }
    for input in inputs {
      guard case .object(let entry) = input, case .string(let path)? = entry["path"],
        case .string(let mode)? = entry["mode"], let bits = Int(mode, radix: 8)
      else { throw CocoaError(.coderInvalidValue) }
      let destination: URL
      if path.hasPrefix("\(Self.invocations)/") {
        destination = Self.state.appending(path: path)
      } else {
        destination = Self.root.appending(path: path)
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Data(contentsOf: Self.oracle.appending(path: "inputs/\(path)")).write(to: destination)
      guard chmod(destination.path, mode_t(bits)) == 0 else { throw POSIXError(.EIO) }
    }
    try openStores()
    guard let found = try targets.find(targetID: targetID) else {
      throw CocoaError(.coderValueNotFound)
    }
    target = found
    var documents: [String: String] = [:]
    for (label, value) in named {
      guard case .string(let identity) = value else { throw CocoaError(.coderInvalidValue) }
      documents[label] = identity
    }
    let exchanges = try recorded.map { value -> Exchange in
      guard case .object(let entry) = value, case .string(let name)? = entry["name"],
        let setup = entry["setup"], case .string(let method)? = entry["method"],
        case .object(let params)? = entry["params"]
      else { throw CocoaError(.coderInvalidValue) }
      return Exchange(name: name, setup: try Setup(recorded: setup), method: method, params: params)
    }
    return (lease, documents, exchanges)
  }
}
