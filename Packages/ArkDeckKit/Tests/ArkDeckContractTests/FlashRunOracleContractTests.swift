// Shared Swift oracle for the Rust Runtime's Flash admission and execution
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

/// Swift `job.submit`, `job.run`, `job.cancel` and `job.reconcile` for the
/// canonical Flash operation (`flash.full-restore@1`) and its compatibility
/// alias (`flash.dayu200`), through the daemon's control-plane handler, with
/// the ArkForge lane, the Rockchip dispatcher and the target facts scripted.
///
/// Nothing here reaches a device, `arkforged`, HDC or an installed service.
/// The lane is a fake of `RuntimeJobEngine.ArkForgeLane`, as the engine's own
/// contract tests fake it (`CompleteOverwriteRecoveryContractTests`): a real
/// `arkforged` always binds the native USB write port, so it cannot stand in
/// for a device. What the fakes answer is fixture data, never device evidence.
///
/// Every story starts from the same root: the Artifact root and Target store
/// the Flash `job.plan` oracle (`flash-plan`) left after importing its bundle,
/// laid down as recorded (`inputs/`), and empty Job, Session and Session owner
/// roots, under one daemon composition. Each exchange names what the fakes
/// answer while it runs (`script`) and records the calls they received
/// (`laneCalls`, `dispatchCalls`); a `restart` exchange drops the composition
/// and composes the daemon again over the same root, recovering its active
/// Jobs as the daemon does when it starts. What a story leaves below the root
/// is recorded after its last exchange: the Job index as a reader observes it,
/// every entry's kind and mode, and every file's bytes, each Job record's
/// machine facts labelled.
///
/// One line of a Job's timeline measures time on the host's monotonic clock:
/// how long the run waited for the lane's archive prewarm before consuming its
/// capability. The oracle keeps that line with its measurement labelled
/// (`consume wait <ms> ms`), in answers and files alike.
///
/// Record a new oracle with `ARKDECK_RUST_FLASH_RUN_RECORD=/private/tmp/<new
/// directory>`; otherwise the checked-in oracle must match byte for byte.
final class FlashRunOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/flash-run", directoryHint: .isDirectory)
  /// Where a new recording takes the imported bundle from.
  private static let planOracle = repository.appending(
    path: "rust/tests/fixtures/flash-plan", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_FLASH_RUN_RECORD"
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-flash-run-oracle", directoryHint: .isDirectory)
  /// Serializes every user of the fixed root, Rust replays included.
  private static let lockPath = "/private/tmp/arkdeck-flash-run-oracle.lock"
  private static let nowUTC = "2026-09-25T00:00:00Z"
  private static let nowPreciseUTC = "2026-09-25T00:00:00.000Z"
  private static let home = "/private/tmp/arkdeck-flash-run-oracle/home"
  private static let quotaBytes = 8 * 1024 * 1024 * 1024
  /// The exact `id@version` the lane's `arkforged` filed its DeviceProfile under.
  private static let profileID = "org.openharmony.dayu200@1.0.0"
  private static let connectKey = "150100424a544e4600"
  private static let aliasKey = "post-flash-hdc-address"
  /// The lane's toolchain, which every StepPermit binds.
  private static let toolchain = String(repeating: "c", count: 64)
  /// The configured `arkforged` the facts port names.
  private static let arkforged = String(repeating: "b", count: 64)
  /// What the fake capture of the post-flash HiLog answers: one line names a
  /// path in the configured home, which the Artifact store redacts.
  private static let hilog =
    "09-25 00:00:00.000  1234  1234 I A00001/fixture: post-flash boot complete\n"
    + "09-25 00:00:00.001  1234  1234 I A00001/fixture: opened /private/tmp/arkdeck-flash-run-oracle/home/.config/app\n"

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Fakes

  /// What the fakes answer while one exchange runs; recorded with it.
  private struct Script {
    /// The lane's archive prewarm: `storeHit`, `imported`, `refused`, or
    /// `drifted` (a receipt for another archive).
    var prewarm = "storeHit"
    /// Creating the daemon job: `ok`, `failed`, `confirmedNotExecuted`, or
    /// `uncorrelated` (a daemon job bound to another toolchain).
    var prepare = "ok"
    /// Driving the prepared job: `ok`, `failed`, `confirmedNotExecuted`,
    /// `outcomeUnknown`, `lost` (an error that is not a dispatch failure) or
    /// `nonCanonical` (a completion receipt whose evidence digest is wrong).
    var perform = "ok"
    /// Observing the correlated daemon job: `none`, `completed`,
    /// `cancelledSafe`, `confirmedFailed`, `outcomeUnknown` or `unreachable`.
    var terminal = "none"
    /// The post-flash HiLog capture: `hilog` or `failed`.
    var diagnostics = "hilog"
    /// The facts port's durable cross-mode binding.
    var crossMode = "satisfied"
    /// The confirmed HDC-normal USB topology, or none.
    var aliasTopology: String? = "42"
    var bindingRevision = 1

    var recorded: JSONValue {
      .object([
        "prewarm": .string(prewarm), "prepare": .string(prepare),
        "perform": .string(perform), "terminal": .string(terminal),
        "diagnostics": .string(diagnostics), "crossMode": .string(crossMode),
        "aliasTopology": aliasTopology.map(JSONValue.string) ?? .null,
        "bindingRevision": .integer(Int64(bindingRevision)),
      ])
    }
  }

  /// The script the fakes read and the calls they received, shared by the
  /// lane, the dispatcher and the facts port across daemon restarts.
  private final class Fakes: @unchecked Sendable {
    private let lock = NSLock()
    private var script = Script()
    private var laneCalls: [String] = []
    private var dispatchCalls: [String] = []
    private var executions = 0

    func begin(_ script: Script) {
      lock.withLock {
        self.script = script
        laneCalls = []
        dispatchCalls = []
      }
    }

    var current: Script { lock.withLock { script } }
    func lane(_ call: String) { lock.withLock { laneCalls.append(call) } }
    func dispatched(_ call: String) { lock.withLock { dispatchCalls.append(call) } }
    func calls() -> (lane: [String], dispatch: [String]) {
      lock.withLock { (laneCalls, dispatchCalls) }
    }

    /// The daemon names its jobs uniquely across its own restarts.
    func nextExecution() -> Int {
      lock.withLock {
        executions += 1
        return executions
      }
    }
  }

  private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
  }

  /// The ArkForge lane, answering as the exchange's script says. Its cache of
  /// completed plans is its own, as the production lane's is: a restart loses
  /// it.
  private actor Lane: RuntimeJobEngine.ArkForgeLane {
    nonisolated let toolchainSHA256 = FlashRunOracleContractTests.toolchain
    private let fakes: Fakes
    private var completed: [String: ArkForgeActionReceiptSummary] = [:]

    init(fakes: Fakes) { self.fakes = fakes }

    func prewarmArtifact(
      jobID: String, artifact: ArkForgeLaneArtifact
    ) async throws -> ArkForgeLaneArtifactPrewarmReceipt {
      fakes.lane("prewarm \(jobID) sha256=\(artifact.sha256) profile=\(artifact.profileID)")
      switch fakes.current.prewarm {
      case "refused":
        throw FixtureFailure(description: "fixture ArkForge content store unavailable")
      case "imported":
        return ArkForgeLaneArtifactPrewarmReceipt(
          artifactSHA256: artifact.sha256, profileID: artifact.profileID,
          imported: true, durationMilliseconds: 11)
      case "drifted":
        return ArkForgeLaneArtifactPrewarmReceipt(
          artifactSHA256: String(repeating: "0", count: 64), profileID: artifact.profileID,
          imported: false, durationMilliseconds: 7)
      default:
        return ArkForgeLaneArtifactPrewarmReceipt(
          artifactSHA256: artifact.sha256, profileID: artifact.profileID,
          imported: false, durationMilliseconds: 7)
      }
    }

    func finishArtifactPrewarm(jobID: String) async {
      fakes.lane("finishPrewarm \(jobID)")
    }

    func prepareExecution(
      jobID: String, artifact: ArkForgeLaneArtifact,
      binding: ArkForgeLaneDeviceBinding, executionPurpose: String
    ) async throws -> RuntimeArkForgeLaneExecution {
      fakes.lane(
        "prepare \(jobID) purpose=\(executionPurpose) target=\(binding.targetID) "
          + "revision=\(binding.bindingRevision) identity=\(binding.stableIdentitySHA256) "
          + "connectKey=\(binding.connectKey) topology=\(binding.usbTopology) "
          + "sha256=\(artifact.sha256) profile=\(artifact.profileID)")
      switch fakes.current.prepare {
      case "failed":
        throw RuntimeDispatchFailure.failed("fixture arkforged refused to materialize the plan")
      case "confirmedNotExecuted":
        throw RuntimeDispatchFailure.confirmedNotExecuted(
          "fixture arkforged created no daemon job")
      default:
        break
      }
      let ordinal = fakes.nextExecution()
      return RuntimeArkForgeLaneExecution(
        arkDeckJobID: jobID, daemonJobID: "JOB-FLASH-\(ordinal)",
        planID: "PLAN-FLASH-\(ordinal)", planSHA256: String(repeating: "7", count: 64),
        executionPurpose: executionPurpose,
        artifactSHA256: artifact.sha256, artifactProfileID: artifact.profileID,
        targetID: binding.targetID, bindingRevision: binding.bindingRevision,
        stableIdentitySHA256: binding.stableIdentitySHA256,
        usbTopology: binding.usbTopology, observationMode: "loader",
        toolchainSHA256: fakes.current.prepare == "uncorrelated"
          ? String(repeating: "d", count: 64) : toolchainSHA256)
    }

    func performPrepared(
      stepID: String, execution: RuntimeArkForgeLaneExecution,
      artifact _: ArkForgeLaneArtifact, binding _: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary {
      fakes.lane(
        "perform \(stepID) \(execution.arkDeckJobID) daemonJob=\(execution.daemonJobID) "
          + "plan=\(execution.planID) purpose=\(execution.executionPurpose)")
      switch fakes.current.perform {
      case "failed":
        throw RuntimeDispatchFailure.failed("fixture arkforged confirmed the plan failed")
      case "confirmedNotExecuted":
        throw RuntimeDispatchFailure.confirmedNotExecuted(
          "fixture arkforged confirmed nothing was written")
      case "outcomeUnknown":
        throw RuntimeDispatchFailure.outcomeUnknown(
          "fixture lost the controller after the daemon accepted the exact job")
      case "lost":
        throw FixtureFailure(description: "fixture controller connection reset")
      case "nonCanonical":
        return Self.receipt(for: execution, canonical: false)
      default:
        let receipt = Self.receipt(for: execution, canonical: true)
        completed[execution.arkDeckJobID] = receipt
        return receipt
      }
    }

    func observeTerminal(
      execution: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome? {
      fakes.lane("observe \(execution.arkDeckJobID) daemonJob=\(execution.daemonJobID)")
      switch fakes.current.terminal {
      case "completed":
        let receipt = Self.receipt(for: execution, canonical: true)
        completed[execution.arkDeckJobID] = receipt
        return .completed(receipts: [receipt])
      case "cancelledSafe":
        return .cancelledSafe(receipts: [])
      case "confirmedFailed":
        return .confirmedFailed(reason: "fixture daemon confirmed the plan failed", receipts: [])
      case "outcomeUnknown":
        return .outcomeUnknown(
          reason: "fixture daemon still cannot prove the outcome", receipts: [])
      case "unreachable":
        throw FixtureFailure(description: "fixture daemon socket unreachable")
      default:
        return nil
      }
    }

    func completedPlanReceipt(jobID: String) async -> ArkForgeActionReceiptSummary? {
      fakes.lane("completedPlanReceipt \(jobID)")
      return completed[jobID]
    }

    /// The terminal managed-control postflight of one completed plan, as the
    /// production lane exposes it; a non-canonical one carries a zero digest.
    static func receipt(
      for execution: RuntimeArkForgeLaneExecution, canonical: Bool
    ) -> ArkForgeActionReceiptSummary {
      let facts = [
        ArkForgeKeyValue(key: "const.product.model", value: "DAYU200"),
        ArkForgeKeyValue(key: "const.ohos.fullname", value: "OpenHarmony-7.0.0.36"),
        ArkForgeKeyValue(key: "usbTopology", value: execution.usbTopology),
      ]
      let ordinal = execution.daemonJobID.dropFirst("JOB-FLASH-".count)
      return ArkForgeActionReceiptSummary(
        jobID: execution.daemonJobID, planID: execution.planID, stepID: "STEP-023",
        actionID: "", attemptID: "", permitID: "PERMIT-FLASH-\(ordinal)",
        disposition: "semanticSuccess",
        evidenceSHA256: canonical
          ? ArkForgeManagedControlPort.canonicalFactsDigest(
            Dictionary(uniqueKeysWithValues: facts.map { ($0.key, $0.value) }))
          : [UInt8](repeating: 0, count: 32),
        verificationOutcome: "", verificationStrength: "",
        verifiedRangeStart: 0, verifiedRangeLength: 0,
        typedSkipReason: "", failureClassification: "", facts: facts)
    }
  }

  /// The Rockchip dispatcher: the one host-managed action a delegated Flash
  /// still runs itself is the optional post-flash HiLog capture.
  private struct Dispatcher: RuntimeProcessDispatching {
    let fakes: Fakes

    func unavailableReason(providerID _: String) -> String? { nil }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      guard case .hostManaged(let descriptor) = plan.kind else {
        fakes.dispatched("a plan that is not host-managed")
        throw RuntimeDispatchFailure.failed(
          "the Flash oracle dispatches only host-managed Rockchip actions")
      }
      fakes.dispatched(
        "\(descriptor.stepID) \(descriptor.jobID) identifier=\(descriptor.identifier) "
          + "target=\(descriptor.targetID) revision=\(descriptor.bindingRevision) "
          + "connectKey=\(descriptor.connectKey) identity=\(descriptor.expectedIdentitySHA256) "
          + "tool=\(descriptor.providerExecutableSHA256) action=\(descriptor.actionSHA256) "
          + "budget=\(plan.outputByteBudget.map { String($0) } ?? "none")")
      guard descriptor.stepID == "capture-post-flash-diagnostics" else {
        throw RuntimeDispatchFailure.failed(
          "the Flash oracle dispatches only the post-flash diagnostics capture")
      }
      guard fakes.current.diagnostics == "hilog" else {
        throw RuntimeDispatchFailure.failed("post-flash HiLog capture returned no bytes")
      }
      let stdout = Data(FlashRunOracleContractTests.hilog.utf8)
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: stdout, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.25,
        hostManagedRecordID: "rockchip-record-\(descriptor.jobID)-\(descriptor.stepID)",
        hostManagedSummary: [
          "byteCount": String(stdout.count), "debugRuntime": "ready", "verification": "full",
        ],
        subprocesses: [
          ProviderSubprocessReceipt(
            exitStatus: 0, stdout: stdout, stderr: Data(), stdoutTruncated: false,
            durationSeconds: 0.25)
        ])
    }
  }

  /// The ArkForge facts port: a covered, post-flash-routed DAYU200, as the
  /// exchange's script shapes it.
  private struct Facts: RockchipRuntimeFactsPort {
    let fakes: Fakes

    func currentFacts(targetID: String) async throws -> ProviderFacts {
      let script = fakes.current
      var server: [String: String] = [
        "rockusbBackend": "native",
        "arkForgeToolchainID": ArkForgeNativeRockUSBToolchain.identifier,
        "dayu200CrossModeBinding": script.crossMode,
      ]
      if let topology = script.aliasTopology {
        server["dayu200HDCNormalAliasSHA256"] = FlashRunOracleContractTests.digest(
          FlashRunOracleContractTests.aliasKey)
        server["dayu200HDCNormalAliasUSBTopology"] = topology
      }
      return ProviderFacts(
        providerID: CatalogProvider.arkforge.rawValue,
        toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
        toolSHA256: FlashRunOracleContractTests.arkforged, serverFacts: server,
        targetID: targetID, bindingRevision: script.bindingRevision,
        deviceIdentitySHA256: FlashRunOracleContractTests.digest(
          FlashRunOracleContractTests.connectKey),
        executionConnectKey: FlashRunOracleContractTests.aliasKey, deviceMode: "hdc",
        buildFingerprint: nil, profileID: "dayu200",
        collectedAtUTC: FlashRunOracleContractTests.nowUTC)
    }
  }

  // MARK: Composition

  /// The daemon's engine and handler over the fixed root, as the daemon
  /// composes them for Flash: the ArkForge provider with the scripted facts,
  /// the scripted lane and dispatcher, the Artifact store with its quota and
  /// redaction, the capability store inside the Job root, and the Session
  /// writer over the root's own Sessions and owner directories.
  private static func compose(
    _ fakes: Fakes
  ) throws -> (handler: RuntimeControlPlaneHandler, engine: RuntimeJobEngine) {
    let targets = try RuntimeTargetStore(
      directoryURL: root.appending(path: "targets-state", directoryHint: .isDirectory))
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      quota: ArtifactQuota(totalBytes: quotaBytes),
      redaction: ArtifactRedactionPolicy(homeDirectory: home), nowUTC: { nowUTC })
    let store = root.appending(path: "store", directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: store.appending(path: "capabilities", directoryHint: .isDirectory))
    let writer = RuntimeSessionPublicationWriter(
      owner: try RuntimeSessionStorageStore(
        ownerRoot: root.appending(path: "session-owner", directoryHint: .isDirectory),
        defaultSessionsRoot: root.appending(path: "Sessions", directoryHint: .isDirectory)),
      coordinator: HostStorageCoordinator(), probe: HDCOracleHarness.RoomyStorageProbe())
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: store, arkForgeLane: Lane(fakes: fakes),
        arkForgeDeviceProfileID: profileID, sessionPublicationWriter: writer),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(factsPort: Facts(fakes: fakes), availability: .available)
      ]),
      dispatcher: Dispatcher(fakes: fakes),
      capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { nowUTC }, nowPreciseUTC: { nowPreciseUTC })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: ["arkforge"],
      nowUTC: { nowUTC }, targetStore: targets, bootstrap: nil,
      artifactStore: artifacts, flashBundleImportDirectory: nil,
      flashBundleImportPolicy: .production, methodObserver: nil)
    return (handler, engine)
  }

  /// One story over the fixed root: its composition, its fakes and what it
  /// has recorded.
  private final class Story {
    let fakes = Fakes()
    var handler: RuntimeControlPlaneHandler?
    var exchanges: [JSONValue] = []
    let targetID: String
    let lease: String
    let otherLease: String

    init(targetID: String, lease: String, otherLease: String) throws {
      self.targetID = targetID
      self.lease = lease
      self.otherLease = otherLease
      handler = try FlashRunOracleContractTests.compose(fakes).handler
    }

    /// Sends one request while the fakes answer as `script` says, and
    /// records it with the calls they received.
    @discardableResult
    func send(
      _ name: String, _ method: String, _ params: [String: JSONValue],
      script: Script = Script()
    ) async throws -> JSONValue {
      guard let handler else { throw CocoaError(.coderInvalidValue) }
      fakes.begin(script)
      let answer = try await HDCOracleHarness.send(
        handler, method, params, frameID: "flash-run-oracle")
      let calls = fakes.calls()
      exchanges.append(
        .object([
          "name": .string(name), "method": .string(method), "params": .object(params),
          "script": script.recorded,
          "answer": try FlashRunOracleContractTests.normalized(
            HDCOracleHarness.revisionIndependent(answer)),
          "laneCalls": .array(calls.lane.map(JSONValue.string)),
          "dispatchCalls": .array(calls.dispatch.map(JSONValue.string)),
        ]))
      return answer
    }

    /// The daemon stops and starts again over the same root: a new engine
    /// and lane recover the active Jobs, as the daemon does before it
    /// listens.
    func restart(_ name: String) async throws {
      handler = nil
      fakes.begin(Script())
      let composed = try FlashRunOracleContractTests.compose(fakes)
      let recovered = try await composed.engine.recoverActiveJobs()
      handler = composed.handler
      let calls = fakes.calls()
      exchanges.append(
        .object([
          "name": .string(name), "method": .string("<restart>"), "params": .object([:]),
          "script": Script().recorded,
          "answer": .object([
            "recovered": .array(
              recovered.map { status -> JSONValue in
                .object(["jobId": .string(status.jobID), "state": .string(status.state)])
              })
          ]),
          "laneCalls": .array(calls.lane.map(JSONValue.string)),
          "dispatchCalls": .array(calls.dispatch.map(JSONValue.string)),
        ]))
    }

    /// A request document for the canonical operation, or for the alias with
    /// its own input names.
    func request(
      _ id: String, alias: Bool = false, version: Int? = nil, verification: String = "full",
      partitions: [String]? = nil, lease: String? = nil, capability: String? = nil,
      reviewed: String? = nil
    ) throws -> [String: JSONValue] {
      let inputs: [String: JSONValue]
      var operation: [String: JSONValue]
      if alias {
        inputs = [
          "imageBundleLease": .string(lease ?? self.lease),
          "deviceProfile": .string("dayu200"),
          "partitionPlan": .array(
            (partitions ?? RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName))
              .map(JSONValue.string)),
          "postFlashVerification": .string(verification),
        ]
        operation = ["id": .string("flash.dayu200")]
      } else {
        inputs = [
          "artifactLease": .string(lease ?? self.lease), "deviceProfileRef": .string("dayu200"),
          "intent": .string("fullRestore"), "verification": .string(verification),
        ]
        operation = ["id": .string("flash.full-restore"), "version": .integer(1)]
      }
      if let version { operation["version"] = .integer(Int64(version)) }
      var document: [String: JSONValue] = [
        "documentType": .string("runtime-operation-request"),
        "schemaVersion": .string("1.0.0"),
        "requestId": .string("req-flash-\(id)"),
        "idempotencyKey": .string("idem-flash-\(id)"),
        "target": .object([
          "targetId": .string(targetID), "expectedBindingRevision": .integer(1),
        ]),
        "operation": .object(operation),
        "inputs": .object(inputs),
      ]
      if let capability {
        document["authorization"] = .object(["capabilityId": .string(capability)])
      }
      if let reviewed { document["reviewedPlanDigest"] = .string(reviewed) }
      return [
        "requestJson": .string(
          String(
            decoding: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document)),
            as: UTF8.self))
      ]
    }

    /// Submits `params` and answers the admitted Job, or nil when refused.
    func submit(
      _ name: String, _ params: [String: JSONValue], script: Script = Script()
    ) async throws -> String? {
      let answer = try await send(name, "job.submit", params, script: script)
      guard case .object(let fields) = answer, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else { return nil }
      return job
    }

    /// Every read of one Job: its status, result, evidence and Artifacts.
    func reads(_ name: String, _ job: String) async throws {
      let id: [String: JSONValue] = ["jobId": .string(job)]
      try await send("\(name).status", "job.status", id)
      try await send("\(name).result", "job.result", id)
      try await send("\(name).evidence", "job.evidence", id)
      try await send(
        "\(name).artifacts", "artifact.list",
        ["owner": .object(["kind": .string("job"), "id": .string(job)]), "pageSize": .integer(1000)])
    }
  }

  // MARK: Normalization and recording

  private static let consumeWait = try! NSRegularExpression(pattern: "consume wait [0-9]+ ms")

  /// A text with the prewarm's measured wait labelled.
  private static func normalized(_ text: String) -> String {
    consumeWait.stringByReplacingMatches(
      in: text, range: NSRange(location: 0, length: (text as NSString).length),
      withTemplate: "consume wait <ms> ms")
  }

  private static func normalized(_ data: Data) -> Data {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    return Data(normalized(text).utf8)
  }

  private static func normalized(_ value: JSONValue) throws -> JSONValue {
    let text = String(
      decoding: try CanonicalJSONEncoders.canonical().encode(value), as: UTF8.self)
    return try JSONDecoder().decode(JSONValue.self, from: Data(normalized(text).utf8))
  }

  private static func encoded(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }

  /// The inputs every story starts from: `(path, mode, bytes)` below the root.
  private static func inputs(recording: Bool) throws -> [(String, Int, Data)] {
    var laid: [(String, Int, Data)] = []
    if recording {
      let cases = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: planOracle.appending(path: "cases.json")))
      guard case .object(let fields) = cases, case .array(let inputs)? = fields["inputs"] else {
        throw CocoaError(.coderInvalidValue)
      }
      for input in inputs {
        guard case .object(let entry) = input, case .string(let path)? = entry["path"],
          case .string(let mode)? = entry["mode"], let bits = Int(mode, radix: 8)
        else { throw CocoaError(.coderInvalidValue) }
        if path.hasPrefix("../targets/") {
          let relative = String(path.dropFirst("../targets/".count))
          laid.append(
            (
              "targets-state/\(relative)", bits,
              try Data(contentsOf: planOracle.appending(path: "inputs/targets/\(relative)"))
            ))
        } else {
          laid.append(
            (
              "artifacts/\(path)", bits,
              try Data(contentsOf: planOracle.appending(path: "inputs/artifacts/\(path)"))
            ))
        }
      }
    } else {
      let listed = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: oracle.appending(path: "inputs.json")))
      guard case .array(let inputs) = listed else { throw CocoaError(.coderInvalidValue) }
      for input in inputs {
        guard case .object(let entry) = input, case .string(let path)? = entry["path"],
          case .string(let mode)? = entry["mode"], let bits = Int(mode, radix: 8)
        else { throw CocoaError(.coderInvalidValue) }
        laid.append((path, bits, try Data(contentsOf: oracle.appending(path: "inputs/\(path)"))))
      }
    }
    return laid
  }

  /// The root as every story finds it: the inputs laid down, the Job, Session
  /// and Session owner roots empty.
  private static func layDown(_ inputs: [(String, Int, Data)]) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: root)
    for directory in ["", "targets-state", "artifacts", "store", "Sessions", "session-owner"] {
      try manager.createDirectory(
        at: root.appending(path: directory, directoryHint: .isDirectory),
        withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    for (path, mode, bytes) in inputs {
      let url = root.appending(path: path)
      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try bytes.write(to: url)
      guard chmod(url.path, mode_t(mode)) == 0 else { throw POSIXError(.EPERM) }
    }
  }

  /// The Artifact pager's continuation snapshots, each named by a random
  /// revision its contents repeat.
  private static let artifactSnapshots = "artifacts/.imports-v1/artifact-snapshots/snapshot-"

  /// What a story leaves below the root: the Job index as a reader observes
  /// it, every entry's kind and mode, and every regular file's bytes, each
  /// Job record's machine facts labelled. A payload's verification cache pins
  /// its inode, so the oracle keeps that it exists and its mode, not its
  /// bytes; an Artifact pager's snapshot is kept the same way, its random
  /// revision labelled; the Job index's database files are kept as its
  /// reader's view.
  private static func leftovers(_ story: String) throws -> [String: Data] {
    var files: [String: Data] = [:]
    var tree: [JSONValue] = []
    for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
      if path.hasPrefix("store/\(RuntimeJobRepository.filename)") { continue }
      let url = root.appending(path: path)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
      let type = metadata.st_mode & S_IFMT
      let snapshot = path.hasPrefix(artifactSnapshots)
      tree.append(
        .object([
          "path": .string(snapshot ? "\(artifactSnapshots)<revision>.json" : path),
          "kind": .string(type == S_IFDIR ? "directory" : type == S_IFLNK ? "symlink" : "file"),
          "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
        ]))
      guard type == S_IFREG, url.lastPathComponent != ".payload-verification-v1.json", !snapshot
      else {
        continue
      }
      let data = try Data(contentsOf: url)
      files["stories/\(story)/files/\(path)"] = normalized(
        url.lastPathComponent == "job-record.json"
          ? HDCOracleHarness.machineIndependent(data) : data)
    }
    files["stories/\(story)/tree.json"] = try encoded(.array(tree))
    files["stories/\(story)/index.json"] = try encoded(
      try HDCOracleHarness.index(of: root.appending(path: "store", directoryHint: .isDirectory)))
    return files
  }

  // MARK: The oracle

  func testSwiftSubmitsAndRunsEveryFlashStoryAsTheRustRuntimeReplays() async throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EBUSY) }
    defer { try? FileManager.default.removeItem(at: Self.root) }

    let recording = ProcessInfo.processInfo.environment[Self.recordVariable] != nil
    let inputs = try Self.inputs(recording: recording)
    let planCases = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        contentsOf: (recording ? Self.planOracle : Self.oracle).appending(
          path: recording ? "cases.json" : "leases.json")))
    guard case .object(let named) = planCases, case .string(let targetID)? = named["targetId"],
      case .string(let lease)? = named["lease"]
    else { throw CocoaError(.coderInvalidValue) }
    // The bundle bound to another Target, which the plan oracle imported
    // last: its lease names the other Import's one Artifact.
    let otherLease: String
    if case .string(let recorded)? = named["otherLease"] {
      otherLease = recorded
    } else {
      let payloads = inputs.map(\.0).compactMap { path -> String? in
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[1].hasPrefix("imp-"), parts[2].hasPrefix("ART-") else {
          return nil
        }
        return "lease-v1:\(parts[1]):\(parts[2])"
      }
      guard let other = payloads.first(where: { $0 != lease }), payloads.count == 2 else {
        throw CocoaError(.coderValueNotFound)
      }
      otherLease = other
    }

    var files: [String: Data] = [:]
    for (path, _, bytes) in inputs { files["inputs/\(path)"] = bytes }
    files["inputs.json"] = try Self.encoded(
      .array(
        inputs.map { path, mode, _ in
          .object(["path": .string(path), "mode": .string(String(mode, radix: 8))])
        }))
    files["leases.json"] = try Self.encoded(
      .object([
        "targetId": .string(targetID), "lease": .string(lease),
        "otherLease": .string(otherLease),
      ]))

    let stories: [(String, (Story) async throws -> Void)] = [
      ("admission", Self.admission), ("canonical", Self.canonical), ("alias", Self.alias),
      ("failures", Self.failures), ("reconcile", Self.reconcile),
      ("recovery", Self.recovery), ("recoveryAlias", Self.recoveryAlias),
      ("cancel", Self.cancel),
    ]
    for (name, body) in stories {
      try Self.layDown(inputs)
      var story: Story? = try Story(targetID: targetID, lease: lease, otherLease: otherLease)
      try await body(story!)
      files["stories/\(name)/cases.json"] = try Self.encoded(
        .object(["exchanges": .array(story!.exchanges)]))
      story = nil
      files.merge(try Self.leftovers(name)) { _, new in new }
    }
    files["provenance.json"] = try Self.encoded(
      .object([
        "producer": .string(
          "FlashRunOracleContractTests.testSwiftSubmitsAndRunsEveryFlashStoryAsTheRustRuntimeReplays"),
        "root": .string(Self.root.path),
        "nowUTC": .string(Self.nowUTC),
        "nowPreciseUTC": .string(Self.nowPreciseUTC),
        "home": .string(Self.home),
        "quotaBytes": .integer(Int64(Self.quotaBytes)),
        "availableBytes": .integer(Int64(HDCOracleHarness.RoomyStorageProbe.roomyBytes)),
        "profileId": .string(Self.profileID),
        "toolchainSha256": .string(Self.toolchain),
        "inputsFrom": .string("rust/tests/fixtures/flash-plan (its imported bundle and Target store)"),
        "stories": .array(stories.map { JSONValue.string($0.0) }),
      ]))
    try HDCOracleHarness.recordOrCompare(files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  // MARK: Stories

  /// Admission refusals: nothing is admitted, issued or dispatched.
  private static func admission(_ story: Story) async throws {
    try await story.send("plan.canonical", "job.plan", try story.request("plan"))
    try await story.send(
      "submit.callerCapability", "job.submit",
      try story.request("caller-capability", capability: "CAP-RT-CALLER-SELECTED"))
    try await story.send(
      "submit.reviewedMismatch", "job.submit",
      try story.request("reviewed-mismatch", reviewed: String(repeating: "0", count: 64)))
    try await story.send(
      "submit.reviewedMalformed", "job.submit",
      try story.request("reviewed-malformed", reviewed: "NOT-A-DIGEST"))
    var unprepared = Script()
    unprepared.crossMode = "unprepared"
    try await story.send(
      "submit.crossModeUnprepared", "job.submit", try story.request("cross-mode"),
      script: unprepared)
    var unrouted = Script()
    unrouted.aliasTopology = nil
    try await story.send(
      "submit.noAlias", "job.submit", try story.request("no-alias"), script: unrouted)
    var stale = Script()
    stale.bindingRevision = 2
    try await story.send(
      "submit.staleRevision", "job.submit", try story.request("stale"), script: stale)
    try await story.send(
      "submit.aliasShortPlan", "job.submit",
      try story.request(
        "alias-short", alias: true,
        partitions: Array(
          RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName).dropLast())))
    try await story.send(
      "submit.aliasVersioned", "job.submit",
      try story.request("alias-versioned", alias: true, version: 1))
    try await story.send(
      "submit.otherTargetLease", "job.submit",
      try story.request("other-target", lease: story.otherLease))
    try await story.send("capabilities", "capability.list", [:])
  }

  /// Two ordinary Flashes of the canonical operation: the first reviewed,
  /// deduplicated and run with its diagnostics captured, the second run with
  /// its archive imported by the lane and its optional capture failing.
  private static func canonical(_ story: Story) async throws {
    let plan = try await story.send("plan", "job.plan", try story.request("first"))
    guard case .object(let planned) = plan, case .object(let result)? = planned["result"],
      case .string(let digest)? = result["materializedPlanDigest"]
    else { throw CocoaError(.coderInvalidValue) }
    let reviewed = try story.request("first", reviewed: digest)
    guard let first = try await story.submit("submit", reviewed) else {
      return XCTFail("canonical: the reviewed Flash was refused")
    }
    try await story.send("submit.duplicate", "job.submit", reviewed)
    try await story.send("status.admitted", "job.status", ["jobId": .string(first)])
    try await story.send("capabilities.admitted", "capability.list", [:])
    try await story.send("run", "job.run", ["jobId": .string(first)])
    try await story.send("run.again", "job.run", ["jobId": .string(first)])
    try await story.reads("first", first)
    try await story.send("capabilities.consumed", "capability.list", [:])

    guard let second = try await story.submit("submit.second", try story.request("second"))
    else { return XCTFail("canonical: the second Flash was refused") }
    var imported = Script()
    imported.prewarm = "imported"
    imported.diagnostics = "failed"
    try await story.send("run.second", "job.run", ["jobId": .string(second)], script: imported)
    try await story.reads("second", second)
    try await story.send("capabilities", "capability.list", [:])
  }

  /// The compatibility alias with basic verification, whose diagnostics are
  /// not selected.
  private static func alias(_ story: Story) async throws {
    guard
      let job = try await story.submit(
        "submit", try story.request("alias-basic", alias: true, verification: "basic"))
    else { return XCTFail("alias: the basic Flash was refused") }
    try await story.send("run", "job.run", ["jobId": .string(job)])
    try await story.reads("alias", job)
    try await story.send("capabilities", "capability.list", [:])
  }

  /// Every way a delegated Flash can end short of success, one Job each, in
  /// order over one store: the prewarm refused, or answered for another
  /// archive, before consumption; the daemon job refused, not created, or
  /// bound to another attempt; the plan confirmed failed or confirmed not
  /// executed; and a completion receipt that fails canonical validation.
  private static func failures(_ story: Story) async throws {
    let cases: [(String, (inout Script) -> Void)] = [
      ("prewarmRefused", { $0.prewarm = "refused" }),
      ("prewarmDrifted", { $0.prewarm = "drifted" }),
      ("prepareFailed", { $0.prepare = "failed" }),
      ("prepareNotExecuted", { $0.prepare = "confirmedNotExecuted" }),
      ("prepareUncorrelated", { $0.prepare = "uncorrelated" }),
      ("performFailed", { $0.perform = "failed" }),
      ("performNotExecuted", { $0.perform = "confirmedNotExecuted" }),
      ("nonCanonical", { $0.perform = "nonCanonical" }),
    ]
    for (name, shape) in cases {
      guard let job = try await story.submit("\(name).submit", try story.request(name)) else {
        XCTFail("failures: \(name) was refused")
        continue
      }
      var script = Script()
      shape(&script)
      try await story.send("\(name).run", "job.run", ["jobId": .string(job)], script: script)
      try await story.send("\(name).status", "job.status", ["jobId": .string(job)])
      try await story.send("\(name).result", "job.result", ["jobId": .string(job)])
    }
    try await story.send("capabilities", "capability.list", [:])
  }

  /// A lost controller parks the Flash; the daemon restarts, and passive
  /// reconciliation of the exact daemon job finds no terminal, then the
  /// completed plan, and the run finishes from that proof. A second Job's
  /// daemon job is found cancelled safely; a third's controller cannot be
  /// reached, and its daemon then answers that it failed without proof.
  private static func reconcile(_ story: Story) async throws {
    guard let first = try await story.submit("first.submit", try story.request("first")) else {
      return XCTFail("reconcile: the first Flash was refused")
    }
    var lost = Script()
    lost.perform = "outcomeUnknown"
    try await story.send("first.run", "job.run", ["jobId": .string(first)], script: lost)
    try await story.restart("restart")
    try await story.send("first.status", "job.status", ["jobId": .string(first)])
    try await story.send("first.reconcile.none", "job.reconcile", ["jobId": .string(first)])
    var completed = Script()
    completed.terminal = "completed"
    try await story.send(
      "first.reconcile.completed", "job.reconcile", ["jobId": .string(first)], script: completed)
    try await story.send("first.run.resumed", "job.run", ["jobId": .string(first)])
    try await story.reads("first", first)

    guard let second = try await story.submit("second.submit", try story.request("second")) else {
      return XCTFail("reconcile: the second Flash was refused")
    }
    try await story.send("second.run", "job.run", ["jobId": .string(second)], script: lost)
    var cancelled = Script()
    cancelled.terminal = "cancelledSafe"
    try await story.send(
      "second.reconcile.cancelledSafe", "job.reconcile", ["jobId": .string(second)],
      script: cancelled)
    try await story.send("second.status", "job.status", ["jobId": .string(second)])

    guard let third = try await story.submit("third.submit", try story.request("third")) else {
      return XCTFail("reconcile: the third Flash was refused")
    }
    var reset = Script()
    reset.perform = "lost"
    try await story.send("third.run", "job.run", ["jobId": .string(third)], script: reset)
    var unreachable = Script()
    unreachable.terminal = "unreachable"
    try await story.send(
      "third.reconcile.unreachable", "job.reconcile", ["jobId": .string(third)],
      script: unreachable)
    var failed = Script()
    failed.terminal = "confirmedFailed"
    try await story.send(
      "third.reconcile.confirmedFailed", "job.reconcile", ["jobId": .string(third)],
      script: failed)
    try await story.send("third.status", "job.status", ["jobId": .string(third)])
    try await story.send("capabilities", "capability.list", [:])
  }

  /// DEC-016: an unknown Flash blocks the target until a complete overwrite
  /// supersedes it. A basic request cannot; a full one is admitted as the
  /// recovery, runs as a superseding execution and establishes the epoch.
  /// Then the same ordinary request is sent again, and recorded as Swift
  /// answers it: the epoch clears the Target's lineage, but the ordinary
  /// policy's last generation still holds the unknown use.
  private static func recovery(_ story: Story) async throws {
    guard let original = try await story.submit("original.submit", try story.request("original"))
    else { return XCTFail("recovery: the original Flash was refused") }
    var lost = Script()
    lost.perform = "outcomeUnknown"
    try await story.send("original.run", "job.run", ["jobId": .string(original)], script: lost)
    try await story.send(
      "basic.submit", "job.submit", try story.request("basic", verification: "basic"))
    guard let recovery = try await story.submit("recovery.submit", try story.request("recovery"))
    else { return XCTFail("recovery: the complete overwrite was refused") }
    try await story.send("capabilities.admitted", "capability.list", [:])
    try await story.send("recovery.run", "job.run", ["jobId": .string(recovery)])
    try await story.reads("recovery", recovery)
    try await story.send("original.status", "job.status", ["jobId": .string(original)])
    if let after = try await story.submit("after.submit", try story.request("after")) {
      try await story.send("after.run", "job.run", ["jobId": .string(after)])
      try await story.send("after.status", "job.status", ["jobId": .string(after)])
    }
    try await story.send("capabilities", "capability.list", [:])
  }

  /// The compatibility alias asked for the complete overwrite after an
  /// unknown canonical Flash.
  private static func recoveryAlias(_ story: Story) async throws {
    guard let original = try await story.submit("original.submit", try story.request("original"))
    else { return XCTFail("recoveryAlias: the original Flash was refused") }
    var lost = Script()
    lost.perform = "outcomeUnknown"
    try await story.send("original.run", "job.run", ["jobId": .string(original)], script: lost)
    guard
      let recovery = try await story.submit(
        "alias.submit", try story.request("alias-recovery", alias: true))
    else { return }
    try await story.send("alias.run", "job.run", ["jobId": .string(recovery)])
    try await story.send("alias.status", "job.status", ["jobId": .string(recovery)])
    try await story.send("capabilities", "capability.list", [:])
  }

  /// An admitted Flash cancelled before it runs, then the next one.
  private static func cancel(_ story: Story) async throws {
    guard let first = try await story.submit("first.submit", try story.request("first")) else {
      return XCTFail("cancel: the Flash was refused")
    }
    try await story.send("first.cancel", "job.cancel", ["jobId": .string(first)])
    try await story.send("first.run", "job.run", ["jobId": .string(first)])
    try await story.send("first.status", "job.status", ["jobId": .string(first)])
    guard let next = try await story.submit("next.submit", try story.request("next")) else {
      return XCTFail("cancel: the next Flash was refused")
    }
    try await story.send("next.run", "job.run", ["jobId": .string(next)])
    try await story.send("next.status", "job.status", ["jobId": .string(next)])
    try await story.send("capabilities", "capability.list", [:])
  }
}
