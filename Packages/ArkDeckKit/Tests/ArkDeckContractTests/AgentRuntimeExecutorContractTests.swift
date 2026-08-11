import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// T00 (DHA-AGENT-001): the Device Runtime Agent drives the runtime
/// itself. These tests run the real runner against a real daemon over its
/// socket - the only substitution is the device.
final class AgentRuntimeExecutorContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var server: AgentDaemonServer?
  private var artifactStore: RuntimeArtifactStore?

  override func setUpWithError() throws {
    stateDirectory = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        ".arkdeck-agent-\(UInt32.random(in: 0..<100_000))", isDirectory: true)
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
    artifactStore = nil
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct FactsPort: HDCObservationFactsPort {
    let store: RuntimeTargetStore
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      let target = try store.find(targetID: targetID)
      return ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: target?.targetID, bindingRevision: target?.bindingRevision,
        deviceIdentitySHA256: target?.stablePhysicalIdentitySHA256,
        executionConnectKey: target?.connectKey,
        deviceModel: nil, deviceMode: "hdc",
        buildFingerprint: nil, transport: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z",
        sourceObservedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private struct HappyDispatcher: RuntimeProcessDispatching {
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      func receipt(_ text: String) -> ProviderProcessReceipt {
        ProviderProcessReceipt(
          exitStatus: 0, stdout: Data(text.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      }
      guard case .hdc(let action) = plan.action else {
        throw RuntimeDispatchFailure.failed("unexpected provider")
      }
      switch action {
      case .observeTool: return receipt("Ver: 3.2.0f\n")
      case .observeServer:
        return receipt("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n")
      case .observeDevice, .listDeviceCandidates:
        return receipt(
          "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
            + "AAA\t\tUSB\tConnected\tlocalhost\n"
            + "BBB\t\tUSB\tConnected\tlocalhost\n")
      case .queryProperty(.productModel):
        return receipt("DAYU200\n")
      case .queryProperty(.fullBuildVersion):
        return receipt("OpenHarmony-4.1-release\n")
      case .observeStorage:
        return receipt(
          "Filesystem 1K-blocks Used Available Use% Mounted on\n"
            + "/dev/block/data 1048576 1024 1047552 1% /data\n")
      case .captureHilog:
        return receipt("01-01 00:00:00 I app: hello\n")
      case .captureUIDump:
        return receipt("{\"windows\":[]}\n")
      default:
        throw RuntimeDispatchFailure.failed("unexpected action \(action)")
      }
    }
  }

  private struct ScriptedBootstrap: BootstrapObservationPort {
    let candidates: @Sendable () -> [BootstrapCandidate]
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates() }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func startDaemon(
    candidates: [BootstrapCandidate] = [
      BootstrapCandidate(connectKey: "150100424a544e4600", state: "Connected")
    ],
    candidateSource: (@Sendable () -> [BootstrapCandidate])? = nil,
    preAdoptedConnectKey: String? = nil,
    observer: (@Sendable (String) -> Void)? = nil
  ) throws -> AgentClient {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    if let preAdoptedConnectKey {
      _ = try targetStore.adopt(
        stableIdentitySHA256: DeviceBootstrapMachine.stableIdentitySHA256(
          serial: preAdoptedConnectKey),
        connectKey: preAdoptedConnectKey, toolVersion: "3.2.0f",
        nowUTC: "2026-07-29T00:00:00Z")
    }
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-29T00:00:00Z" })
    self.artifactStore = artifactStore
    let provider = HDCObservationProviderAdapter(factsPort: FactsPort(store: targetStore))
    let providers = DeviceProviderRegistry(providers: [provider])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: providers, dispatcher: HappyDispatcher(),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let bootstrap = DeviceBootstrapMachine(
      observation: ScriptedBootstrap(candidates: candidateSource ?? { candidates }),
      targetStore: targetStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs, nowUTC: { "2026-07-29T00:00:00Z" },
      targetStore: targetStore, bootstrap: bootstrap, artifactStore: artifactStore,
      methodObserver: observer)
    let server = AgentDaemonServer(
      stateDirectory: stateDirectory, handler: handler, nowUTC: { "2026-07-29T00:00:00Z" })
    guard try server.start() == .started else {
      throw AgentDaemonError.io("daemon did not start")
    }
    self.server = server
    return AgentClient(socketPath: server.socketURL.path)
  }

  private func executor(_ client: AgentClient) -> AgentRuntimeExecutor {
    AgentRuntimeExecutor(client: client, nowUTC: { "2026-07-29T00:00:00Z" })
  }

  // MARK: - The agent drives the runtime

  func testAgentAdoptsAndRunsAnOperationWithoutAnyHumanHostCommand() throws {
    let client = try startDaemon()
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .completed(let receipt) = outcome else {
      return XCTFail("the agent must complete the run: \(outcome)")
    }
    XCTAssertEqual(receipt.executor, .agent, "the receipt must not claim a human ran this")
    XCTAssertEqual(receipt.operationReference, "observe.device@1")
    XCTAssertEqual(receipt.terminalState, "succeeded")
    XCTAssertNotNil(receipt.jobID)
    XCTAssertTrue(receipt.targetID?.hasPrefix("TGT-") == true)
    XCTAssertEqual(receipt.authorityReference, "default-read-only-policy")
    XCTAssertEqual(receipt.actualEffect, .readOnly)
    XCTAssertNotNil(receipt.evidenceObservation)
    XCTAssertFalse(receipt.catalogDigest.isEmpty)
    XCTAssertTrue(receipt.humanActions.isEmpty, "nothing physical was needed here")
    XCTAssertFalse(receipt.artifacts.isEmpty, "the run's products are referenced by ID")
    guard case .published(let evidence) = HardwareEvidenceProjector.project(
      receipt: receipt,
      claims: HardwareEvidenceClaimMetadata(
        evidenceID: "EVD-AHE-RUNNER-001",
        acceptanceIDs: ["AC-WF-004-01"]))
    else {
      return XCTFail("complete daemon-owned receipt must project to V5")
    }
    XCTAssertEqual(evidence.runtime.jobId, receipt.jobID)
    XCTAssertEqual(evidence.device.bindingRevision, receipt.bindingRevision)
  }

  func testHeadlessVerifierClosesUDSRuntimeArtifactAndPostflightWithoutUI() throws {
    let client = try startDaemon()
    let verifier = RuntimeHeadlessVerifier(
      client: client, nowUTC: { "2026-07-29T00:00:00Z" })

    let outcome = try verifier.verifyObserveDevice(
      maximumWaitSeconds: 30, executionID: "headless-contract-001")
    guard case .verified(let report) = outcome else {
      return XCTFail("the headless Runtime chain must close: \(outcome)")
    }

    XCTAssertEqual(report.schemaVersion, "arkdeck-headless-runtime-verification/v1")
    XCTAssertEqual(
      report.classification, "runtimeReceipt",
      "a fixture-backed contract must never label itself REAL_DEVICE_PASS")
    XCTAssertTrue(report.runtimeVerified, "\(report.blockers)")
    XCTAssertTrue(report.checks.udsHealthVerified)
    XCTAssertTrue(report.checks.terminalReceiptVerified)
    XCTAssertTrue(report.checks.trustedEvidenceVerified)
    XCTAssertTrue(report.checks.artifactsVerified)
    XCTAssertTrue(report.checks.runtimePostflightVerified)
    XCTAssertEqual(report.receipt.operationReference, "observe.device@1")
    XCTAssertEqual(report.receipt.terminalState, "succeeded")
    XCTAssertFalse(report.receipt.outcomeUnknown)
    XCTAssertEqual(
      Set(report.artifactInventory.map(\.name)),
      Set(["binding-snapshot.json", "device-facts.json", "tool-facts.json"]))
    XCTAssertTrue(report.artifactInventory.allSatisfy { $0.status == "published" })
    XCTAssertTrue(report.artifactInventory.allSatisfy { $0.jobID == report.receipt.jobID })
  }

  func testDaemonPreservesHistoricalCampaignCorrelationForDecodeOnlyExport() throws {
    let digest = String(repeating: "a", count: 64)
    let currentCorrelation = RuntimeCampaignEvidenceCorrelation(
      campaignID: "ECAMP-0123456789ABCDEF01234567",
      attemptID: "ain019-campaign-attempt-001",
      attemptOrdinal: 1,
      planDigestSHA256: digest,
      targetBindingDigestSHA256: String(repeating: "b", count: 64),
      candidateDigestSHA256: String(repeating: "c", count: 64),
      brokerDigestSHA256: String(repeating: "e", count: 64))
    var historicalJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(currentCorrelation))
        as? [String: Any])
    historicalJSON["reviewDigestSHA256"] = String(repeating: "d", count: 64)
    let correlation = try JSONDecoder().decode(
      RuntimeCampaignEvidenceCorrelation.self,
      from: JSONSerialization.data(withJSONObject: historicalJSON))
    let snapshot = RuntimeJobEvidenceSnapshot(
      jobID: "job-campaign-evidence-001",
      operationReference: "flash.dayu200",
      catalogDigest: String(repeating: "f", count: 64),
      targetID: "TGT-CAMPAIGN-EVIDENCE-001",
      bindingRevision: 7,
      providerID: "rockchip",
      actualEffect: "destructive",
      authority: RuntimeAdmissionEvidence(
        kind: .evolutionCampaignConfirmation,
        reference: "ain019-campaign-attempt-001",
        admittedAtUTC: "2026-08-03T00:00:00Z",
        validUntilUTC: "2026-08-03T04:00:00Z",
        consumptionFingerprintSHA256: digest,
        campaignCorrelation: correlation),
      observation: nil,
      actualStepKinds: ["flashPartition"],
      executionMode: "execute",
      terminalState: "failed",
      outcomeUnknown: false,
      startedAtUTC: "2026-08-03T00:00:01Z",
      firstEvidenceStepAtUTC: "2026-08-03T00:00:01Z",
      finishedAtUTC: "2026-08-03T00:00:02Z",
      recoveryEpoch: nil,
      inputs: ["userdataPolicy": .string("preserve")])
    let encoded = RuntimeControlPlaneHandler.encodeEvidence(
      snapshot: snapshot, artifacts: [], blockers: [])
    guard case .object(let encodedFields) = encoded,
      case .object(let parameterFields)? = encodedFields["parameters"]
    else { return XCTFail("job.evidence must project typed parameters") }
    XCTAssertEqual(parameterFields["userdataPolicy"], .string("preserve"))
    let bytes = try JSONEncoder().encode(encoded)
    let trusted = try JSONDecoder().decode(RuntimeHardwareEvidenceTrustedFacts.self, from: bytes)

    XCTAssertEqual(trusted.authority?.campaignID, correlation.campaignID)
    XCTAssertEqual(trusted.authority?.attemptID, correlation.attemptID)
    XCTAssertEqual(trusted.authority?.attemptOrdinal, correlation.attemptOrdinal)
    XCTAssertEqual(trusted.authority?.planDigest, correlation.planDigestSHA256)
    XCTAssertEqual(trusted.authority?.targetBindingDigest, correlation.targetBindingDigestSHA256)
    XCTAssertEqual(trusted.authority?.candidateDigest, correlation.candidateDigestSHA256)
    XCTAssertEqual(trusted.authority?.reviewDigest, correlation.reviewDigestSHA256)
    XCTAssertEqual(trusted.authority?.brokerDigest, correlation.brokerDigestSHA256)
  }

  func testUnselectedOptionalTraceDoesNotBlockPublishedCaptureEvidence() throws {
    let client = try startDaemon()
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(
        operationID: "capture.diagnostics", operationVersion: 1,
        inputs: ["durationSeconds": .integer(1)]))
    guard case .completed(let receipt) = outcome else {
      return XCTFail("the E0 capture must complete: \(outcome)")
    }
    XCTAssertEqual(receipt.terminalState, "succeeded")
    XCTAssertTrue(receipt.evidenceBlockers.isEmpty, "\(receipt.evidenceBlockers)")
    XCTAssertEqual(
      receipt.artifacts.count, 5,
      "HiLog, UI dump, capture log, index and summary are evidence; unselected Trace is not")
    XCTAssertTrue(receipt.artifacts.allSatisfy(\.bytesVerified))
    XCTAssertFalse(
      receipt.artifacts.contains { $0.reference.contains("ART-MISSING-") },
      "an honest optional omission is index metadata, not an evidence artifact")
  }

  func testUnauthorizedDeviceBecomesAResumableHumanActionNotAFailure() throws {
    let client = try startDaemon(candidates: [
      BootstrapCandidate(connectKey: "150100424a544e4600", state: "Unauthorized")
    ])
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .awaitingHumanAction(let action, let receipt) = outcome else {
      return XCTFail("an untrusted device must pause, not fail: \(outcome)")
    }
    XCTAssertEqual(action.kind, .trustDevice)
    XCTAssertTrue(action.prompt.contains("trust"), action.prompt)
    XCTAssertFalse(action.resumeToken.isEmpty, "the pause must be resumable")
    XCTAssertEqual(receipt.terminalState, "awaitingHumanAction")
    XCTAssertEqual(receipt.humanActions.count, 1)
    XCTAssertEqual(receipt.executor, .agent)
  }

  func testOfflineDeviceRequestsReconnectInsteadOfTrust() throws {
    let client = try startDaemon(candidates: [
      BootstrapCandidate(connectKey: "150100424a544e4600", state: "Offline")
    ])
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .awaitingHumanAction(let action, _) = outcome else {
      return XCTFail("an offline device must pause for reconnect: \(outcome)")
    }
    XCTAssertEqual(action.kind, .physicalReconnect)
    XCTAssertTrue(action.prompt.contains("Reconnect"), action.prompt)
    XCTAssertFalse(action.prompt.contains("trust"), action.prompt)
  }

  func testExplicitAdoptedOfflineTargetPausesBeforeJobAndResumesSameExecution() throws {
    final class CandidateState: @unchecked Sendable {
      private let lock = NSLock()
      private var current = [
        BootstrapCandidate(connectKey: "150100424a544e4600", state: "Offline")
      ]

      func snapshot() -> [BootstrapCandidate] {
        lock.withLock { current }
      }

      func connect() {
        lock.withLock {
          current = [
            BootstrapCandidate(connectKey: "150100424a544e4600", state: "Connected")
          ]
        }
      }
    }

    let candidateState = CandidateState()
    let client = try startDaemon(
      candidateSource: { candidateState.snapshot() },
      preAdoptedConnectKey: "150100424a544e4600")
    guard case .array(let targets) = try client.request(method: "target.list"),
      case .object(let target)? = targets.first,
      case .string(let targetID)? = target["targetId"]
    else {
      return XCTFail("pre-adopted target must be listed")
    }

    let executor = self.executor(client)
    let paused = try executor.run(
      RuntimeAgentExecutionRequest(
        operationID: "observe.device", operationVersion: 1,
        targetID: targetID, executionID: "explicit-offline-resume-001"))
    guard case .awaitingHumanAction(let action, _) = paused else {
      return XCTFail("an explicit offline target must pause before submit: \(paused)")
    }
    XCTAssertEqual(action.kind, .physicalReconnect)
    guard case .array(let jobsBeforeReconnect) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertTrue(
      jobsBeforeReconnect.isEmpty,
      "offline target confirmation must not create a failed runtime Job")

    candidateState.connect()
    let resumed = try executor.resume(resumeToken: action.resumeToken)
    guard case .completed(let receipt) = resumed else {
      return XCTFail("physical reconnect must continue the persisted execution: \(resumed)")
    }
    XCTAssertEqual(receipt.targetID, targetID)
    XCTAssertEqual(receipt.humanActions.count, 1)
    XCTAssertNotNil(receipt.humanActions[0].resolvedAtUTC)
    guard case .array(let jobsAfterReconnect) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertEqual(
      jobsAfterReconnect.count, 1,
      "resume must submit exactly one Job after the target is reachable")
  }

  func testExplicitTargetUsesExactDaemonCandidateOwnershipWithoutHumanSelection() throws {
    let requestedConnectKey = "AAA"
    final class Log: @unchecked Sendable {
      private let lock = NSLock()
      private var methods: [String] = []
      func record(_ method: String) { lock.withLock { methods.append(method) } }
      func snapshot() -> [String] { lock.withLock { methods } }
    }
    let log = Log()
    let client = try startDaemon(
      candidates: [
        BootstrapCandidate(connectKey: requestedConnectKey, state: "Connected"),
        BootstrapCandidate(connectKey: "BBB", state: "Connected"),
      ],
      preAdoptedConnectKey: requestedConnectKey,
      observer: { log.record($0) })
    guard case .array(let targets) = try client.request(method: "target.list"),
      case .object(let requested)? = targets.first,
      case .string(let requestedTargetID)? = requested["targetId"]
    else {
      return XCTFail("pre-adopted requested target must be listed")
    }

    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(
        operationID: "observe.device", operationVersion: 1,
        targetID: requestedTargetID,
        executionID: "explicit-target-exact-owner-001"))
    guard case .completed(let receipt) = outcome else {
      return XCTFail("exact daemon candidate ownership must close headlessly: \(outcome)")
    }
    XCTAssertEqual(receipt.targetID, requestedTargetID)
    XCTAssertTrue(receipt.humanActions.isEmpty)
    XCTAssertTrue(log.snapshot().contains("device.candidates"))
    XCTAssertFalse(
      log.snapshot().contains("target.adopt"),
      "an exact live-to-durable mapping must not repeat bootstrap adoption")
    guard case .array(let jobs) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertEqual(jobs.count, 1, "the exact route must submit one typed Runtime Job")
  }

  func testAmbiguousCandidatesAskForSelectionRatherThanGuessing() throws {
    let client = try startDaemon(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected"),
      BootstrapCandidate(connectKey: "BBB", state: "Connected"),
    ])
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .awaitingHumanAction(let action, _) = outcome else {
      return XCTFail("two candidates must require a choice: \(outcome)")
    }
    XCTAssertEqual(action.kind, .selectTarget)
    XCTAssertTrue(action.prompt.contains("candidates"), action.prompt)
    XCTAssertEqual(action.selectionOptions, ["AAA", "BBB"])
  }

  func testSelectionResumeContinuesThePersistedExecutionInsteadOfRestarting() throws {
    let client = try startDaemon(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected"),
      BootstrapCandidate(connectKey: "BBB", state: "Connected"),
    ])
    let executor = self.executor(client)
    let request = RuntimeAgentExecutionRequest(
      operationID: "observe.device", operationVersion: 1,
      executionID: "resume-contract-001")
    let paused = try executor.run(request)
    guard case .awaitingHumanAction(let action, _) = paused else {
      return XCTFail("ambiguous adoption must pause")
    }
    XCTAssertEqual(action.selectionOptions, ["AAA", "BBB"])

    let resumed = try executor.resume(
      resumeToken: action.resumeToken, selection: "AAA")
    guard case .completed(let receipt) = resumed else {
      return XCTFail("selection must continue the persisted run: \(resumed)")
    }
    XCTAssertEqual(receipt.humanActions.count, 1)
    XCTAssertNotNil(receipt.humanActions[0].resolvedAtUTC)
    guard case .array(let jobs) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertEqual(jobs.count, 1, "resume must not duplicate runtime jobs")
  }

  func testExplicitTargetNeverOffersUnownedCandidatesOrDispatches() throws {
    let client = try startDaemon(
      candidates: [
        BootstrapCandidate(connectKey: "BBB", state: "Connected"),
        BootstrapCandidate(connectKey: "CCC", state: "Connected"),
      ],
      preAdoptedConnectKey: "AAA")
    guard case .array(let targets) = try client.request(method: "target.list"),
      case .object(let original)? = targets.first,
      case .string(let requestedTargetID)? = original["targetId"]
    else {
      return XCTFail("pre-adopted requested target must be listed")
    }

    let executor = self.executor(client)
    let paused = try executor.run(
      RuntimeAgentExecutionRequest(
        operationID: "observe.device", operationVersion: 1,
        targetID: requestedTargetID,
        executionID: "explicit-target-candidate-mismatch-001"))
    guard case .awaitingHumanAction(let reconnect, let receipt) = paused else {
      return XCTFail("unowned physical candidates must pause: \(paused)")
    }
    XCTAssertEqual(reconnect.kind, .physicalReconnect)
    XCTAssertNil(
      reconnect.selectionOptions,
      "raw connect keys that are not owned by the requested target are not valid choices")
    XCTAssertTrue(reconnect.prompt.contains("Reconnect"))
    XCTAssertNil(receipt.jobID)
    guard case .array(let jobs) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertTrue(jobs.isEmpty, "target mismatch must remain zero-dispatch")
  }

  func testAgentSurfaceCannotManageCapabilitiesOrCarryCommands() throws {
    // Behavioural, not textual: drive a real run and assert on the methods
    // the agent actually invoked. Grepping the source would pass on
    // prose - the very trap this file's own header would have sprung.
    let recorder = try startRecordingDaemon()
    _ = try executor(recorder.client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    let called = recorder.observedMethods()
    XCTAssertFalse(called.isEmpty, "the run must have called the daemon")
    for management in ["capability.install", "capability.revoke"] {
      XCTAssertFalse(
        called.contains(management),
        "the agent must never manage capabilities: called \(called)")
    }
    XCTAssertTrue(
      called.allSatisfy { method in
        ["health", "operation.describe", "target.list", "target.adopt", "job.submit", "job.run",
          "job.status", "artifact.list", "job.evidence"].contains(method)
      },
      "the agent may only use the published runtime surface: \(called)")

    // The request type itself offers a capability *reference* and nothing
    // that could carry a document or a command.
    let request = RuntimeAgentExecutionRequest(
      operationID: "debug.hap", operationVersion: 1,
      capabilityReference: "CAP-RT-EXAMPLE-001")
    XCTAssertEqual(request.capabilityReference, "CAP-RT-EXAMPLE-001")
  }

  func testHostOnlyAgentRequestDoesNotAdoptOrPinADevice() throws {
    let recorder = try startRecordingDaemon()
    let outcome = try executor(recorder.client).run(
      RuntimeAgentExecutionRequest(
        operationID: "workspace.build-openharmony", operationVersion: 1,
        inputs: [
          "projectRef": .string("demo-app"),
          "buildPresetRef": .string("waterflow-debug"),
        ],
        executionID: "host-only-workspace-001"))
    guard case .failed(let reason, let receipt) = outcome else {
      return XCTFail("the unregistered fixture provider must reject the host operation")
    }

    XCTAssertEqual(receipt.targetID, "demo-app")
    XCTAssertNil(receipt.bindingRevision)
    XCTAssertFalse(
      reason.contains("is host-only"),
      "the Agent must not manufacture the binding-revision defect: \(reason)")
    let called = recorder.observedMethods()
    XCTAssertTrue(called.contains("operation.describe"))
    XCTAssertTrue(called.contains("job.submit"))
    XCTAssertFalse(called.contains("target.list"), "host-only runs do not need a device")
    XCTAssertFalse(called.contains("target.adopt"), "host-only runs must never adopt a device")
  }

  func testArtifactBoundSigningPreservesItsTargetWithoutAdoptingADevice() throws {
    let recorder = try startRecordingDaemon()
    let outcome = try executor(recorder.client).run(
      RuntimeAgentExecutionRequest(
        operationID: "workspace.sign-openharmony-hap", operationVersion: 1,
        inputs: [
          "projectRef": .string("demo-app"),
          "signingPresetRef": .string("openharmony-release@1"),
          "unsignedHapArtifactLease": .string("lease-v1:source:ART-INPUT"),
        ],
        targetID: "TGT-ARTIFACT-BOUND",
        executionID: "artifact-bound-signing-001"))
    guard case .failed(let reason, let receipt) = outcome else {
      return XCTFail("the fixture lacks the workspace provider and must reject: \(outcome)")
    }

    XCTAssertEqual(receipt.targetID, "TGT-ARTIFACT-BOUND")
    XCTAssertNil(receipt.bindingRevision)
    XCTAssertFalse(reason.contains("does not match projectRef"), reason)
    let called = recorder.observedMethods()
    XCTAssertTrue(called.contains("job.submit"))
    XCTAssertFalse(called.contains("target.list"), "host-only signing must not list devices")
    XCTAssertFalse(called.contains("target.adopt"), "host-only signing must not adopt a device")
  }

  /// A daemon whose handler records which methods were invoked.
  private struct MethodRecorder {
    let client: AgentClient
    let observedMethods: @Sendable () -> [String]
  }

  private func startRecordingDaemon() throws -> MethodRecorder {
    final class Log: @unchecked Sendable {
      private let lock = NSLock()
      private var methods: [String] = []
      func record(_ method: String) { lock.withLock { methods.append(method) } }
      func snapshot() -> [String] { lock.withLock { methods } }
    }
    let log = Log()
    let client = try startDaemon(observer: { log.record($0) })
    return MethodRecorder(client: client, observedMethods: { log.snapshot() })
  }

  func testAgentRunSubmitsAtMostOneJob() throws {
    let client = try startDaemon()
    _ = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .array(let jobs) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertEqual(jobs.count, 1, "one invocation submits exactly one job, never a loop")
  }

  func testE1RunWithoutCapabilityReachesTheJobUnderAutomaticPolicy() async throws {
    let connectKey = "150100424a544e4600"
    let client = try startDaemon(preAdoptedConnectKey: connectKey)
    guard case .array(let targets) = try client.request(method: "target.list"),
      case .object(let target)? = targets.first,
      case .string(let targetID)? = target["targetId"],
      case .integer(let bindingRevision)? = target["bindingRevision"]
    else {
      return XCTFail("pre-adopted target must be listed")
    }
    let store = try XCTUnwrap(artifactStore)
    let artifact = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-agent-input", sessionID: "session-agent-input",
        stepID: "publish-hap", name: "demo.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: targetID, bindingRevision: Int(bindingRevision),
          stableIdentitySHA256:
            DeviceBootstrapMachine.stableIdentitySHA256(serial: connectKey)),
        contents: Data("signed-hap-fixture".utf8)))
    let lease = try await store.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(
        operationID: "debug.hap", operationVersion: 1,
        inputs: [
          "hapArtifactLease": .string(lease),
          "bundleName": .string("com.example.demo"),
          "abilityName": .string("EntryAbility"),
        ]))
    guard case .failed(let reason, let receipt) = outcome else {
      return XCTFail(
        "the fixture lacks E1 actions, so the admitted Job must fail later: \(outcome)")
    }
    XCTAssertFalse(reason.contains("authorizationRequired"), reason)
    XCTAssertEqual(receipt.terminalState, "failed")
    XCTAssertNotNil(receipt.jobID, "automatic E1 authorization must admit a durable job")
    XCTAssertEqual(receipt.executor, .agent)
    XCTAssertEqual(receipt.authority?.kind, .runtimeCapability)
    XCTAssertTrue(receipt.authorityReference.hasPrefix("CAP-RT-POLICY-"))
  }

  private func packageRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "ArkDeckKit" && url.pathComponents.count > 1 {
      url = url.deletingLastPathComponent()
    }
    return url
  }
}

/// The authorization defect the maintainer caught in review: charging the
/// operation's minimum effect would let a plan that mutates the device
/// through on the default read-only policy.
final class EffectiveEffectContractTests: XCTestCase {
  private func capture() throws -> CatalogOperationDescriptor {
    try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
  }

  func testCaptureWithoutTraceIsReadOnly() throws {
    let descriptor = try capture()
    XCTAssertEqual(
      RuntimeJobEngine.effectiveEffect(
        descriptor: descriptor, inputs: ["durationSeconds": .integer(5)]),
      .readOnly)
  }

  func testCaptureWithRemoteTraceEscalatesToDeviceMutation() throws {
    let descriptor = try capture()
    let effect = RuntimeJobEngine.effectiveEffect(
      descriptor: descriptor,
      inputs: [
        "durationSeconds": .integer(5),
        "traceCategories": .array([.string("ohos")]),
      ])
    XCTAssertEqual(
      effect, .deviceMutation,
      "selecting the remote-file trace mutates the device and must be charged as such")
    XCTAssertGreaterThan(
      effect, descriptor.minimumEffect,
      "the operation minimum is exactly the value that would have under-charged this plan")
  }

  func testEmptyTraceCategoriesDoNotEscalate() throws {
    let descriptor = try capture()
    XCTAssertEqual(
      RuntimeJobEngine.effectiveEffect(
        descriptor: descriptor, inputs: ["traceCategories": .array([])]),
      .readOnly)
  }

  func testAlwaysRunStepsStillSetTheFloor() throws {
    let debug = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    XCTAssertEqual(
      RuntimeJobEngine.effectiveEffect(descriptor: debug, inputs: [:]), .deviceMutation)
  }
}
