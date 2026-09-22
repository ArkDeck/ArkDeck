import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckClientKit
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The ClientKit Overview runner is also checked against the existing Swift
/// Runtime/Provider contract. These fixtures are not Rust device acceptance.
final class DebugWindowInventoryJobRunnerContractTests: XCTestCase {
  private static let targetID = "TGT-DAYU200-01"
  private static let bindingRevision = 7
  private static let connectKey = String(repeating: "a", count: 32)
  private static let nowUTC = "2026-09-02T00:00:00Z"

  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-window-inventory-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  func testTheAppComposesTheDebugWindowInventoryTemplateIntoTheOverview() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let runner = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckClientKit/DebugWindowInventoryJobRunner.swift"),
      encoding: .utf8)
    XCTAssertTrue(runner.contains("DebugTemplateJobExecution.run("))
    XCTAssertTrue(
      runner.contains("templateID: DebugRuntimeCommandTemplate.windowInventory.rawValue"))

    let app = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"), encoding: .utf8)
    XCTAssertTrue(
      app.contains(
        "OverviewCapabilityApplicationFacade.make(\n      windowInventory: DebugWindowInventoryJobRunner())"))
  }

  func testOverviewTraceDispositionsMirrorTheProviderWireValues() {
    // Exhaustive on purpose: a new Provider verdict stops this compiling until
    // ClientKit decides how the Overview reads it.
    func mirrored(_ disposition: TraceRuntimeToolDisposition) -> OverviewTraceToolDisposition {
      switch disposition {
      case .captureEligible: .captureEligible
      case .probeOnly: .probeOnly
      case .unrecognized: .unrecognized
      case .probeFailed: .probeFailed
      }
    }
    let provider: [TraceRuntimeToolDisposition] = [
      .captureEligible, .probeOnly, .unrecognized, .probeFailed,
    ]
    for disposition in provider {
      XCTAssertEqual(mirrored(disposition).rawValue, disposition.rawValue)
    }
    XCTAssertEqual(
      Set(OverviewTraceToolDisposition.allCases.map(\.rawValue)),
      Set(provider.map(\.rawValue)))
  }

  /// The defect this pins: `job.run` answers the Job's `arkdeck.job-status/1`
  /// projection, which has carried no timeline since the single-v1 cleanup
  /// (#1733), and the runner decoded that answer as the terminal
  /// presentation. Every run, succeeded or not, then read "Runtime returned
  /// incomplete terminal Debug facts" and the hidumper row stayed unknown.
  /// Here a Runtime control plane in this process answers the runner, which
  /// really runs the Job over scripted HDC receipts.
  func testASucceededWindowInventoryJobMakesTheHidumperRowAvailable() async throws {
    let runtime = try makeRuntime(templateExitStatus: 0)

    let presentation = await overview(runtime).refresh(targetID: nil)

    let answers = await runtime.answers()
    XCTAssertEqual(answers.map(\.method), ["job.submit", "job.run", "job.show"])
    guard case .string(let jobID)? = answers.first?.result["jobId"] else {
      return XCTFail("job.submit must answer the admitted Job")
    }
    // What `job.run` answers for this Job: its terminal status and the Debug
    // commands workspace thread it was filed under, and no timeline.
    let ran = try XCTUnwrap(answers.dropFirst().first?.result)
    XCTAssertEqual(ran["schemaVersion"], .string("arkdeck.job-status/1"))
    XCTAssertEqual(ran["state"], .string("succeeded"))
    XCTAssertEqual(ran["outcomeUnknown"], .bool(false))
    XCTAssertEqual(
      ran["threadId"],
      .string(
        RuntimeWorkspaceThread.identifier(
          clientName: ArkDeckAgentClientName.debugCommandsWorkspace, targetID: Self.targetID)))
    XCTAssertNil(ran["timeline"])
    // The device path ran: the binding confirmation, then the template.
    let actions = runtime.hdc.actions
    XCTAssertEqual(actions.count, 2)
    guard case .hdc(.observeDevice)? = actions.first else {
      return XCTFail("the template must not run before the binding identity is confirmed")
    }
    XCTAssertEqual(actions.last, .hdc(.runDebugTemplate(.windowInventory)))

    XCTAssertEqual(presentation.targetID, Self.targetID)
    XCTAssertEqual(
      presentation.items.first,
      OverviewCapabilityItemPresentation(
        id: "hidumper", name: "hidumper", state: .available,
        evidence: "debug.template@1 Job succeeded · \(jobID)"))
  }

  /// A Job that ran and failed is reported as failed, with its own ID, not as
  /// an incomplete answer.
  func testAFailedWindowInventoryJobLeavesTheRowUnknownUnderItsOwnState() async throws {
    let runtime = try makeRuntime(templateExitStatus: 1)

    let presentation = await overview(runtime).refresh(targetID: nil)

    let answers = await runtime.answers()
    XCTAssertEqual(answers.map(\.method), ["job.submit", "job.run", "job.show"])
    guard case .string(let jobID)? = answers.first?.result["jobId"] else {
      return XCTFail("job.submit must answer the admitted Job")
    }
    XCTAssertEqual(answers.dropFirst().first?.result["state"], .string("failed"))
    XCTAssertEqual(
      presentation.items.first,
      OverviewCapabilityItemPresentation(
        id: "hidumper", name: "hidumper", state: .unknown,
        evidence: "debug.template@1 Job failed · \(jobID)"))
  }

  /// The runner still refuses to guess: a Job status that `job.show` answers
  /// without its state or its outcome certainty is an incomplete answer, and
  /// the row stays unknown with that reason even though the Job succeeded.
  func testAnIncompleteTerminalAnswerStillLeavesTheRowUnknown() async throws {
    for member in ["state", "outcomeUnknown"] {
      let runtime = try makeRuntime(templateExitStatus: 0, withholding: member)

      let presentation = await overview(runtime).refresh(targetID: nil)

      let answers = await runtime.answers()
      XCTAssertEqual(answers.map(\.method), ["job.submit", "job.run", "job.show"], member)
      XCTAssertEqual(answers.dropFirst().first?.result["state"], .string("succeeded"), member)
      XCTAssertEqual(
        presentation.items.first,
        OverviewCapabilityItemPresentation(
          id: "hidumper", name: "hidumper", state: .unknown,
          evidence: "Runtime returned incomplete terminal Debug facts"),
        member)
    }
  }

  // MARK: - In-process Runtime

  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: DebugWindowInventoryJobRunnerContractTests.bindingRevision,
        deviceIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: DebugWindowInventoryJobRunnerContractTests.connectKey),
        executionConnectKey: DebugWindowInventoryJobRunnerContractTests.connectKey,
        deviceModel: nil, deviceMode: "hdc",
        buildFingerprint: nil, transport: nil,
        profileID: "openharmony-standard@1",
        collectedAtUTC: DebugWindowInventoryJobRunnerContractTests.nowUTC,
        sourceObservedAtUTC: DebugWindowInventoryJobRunnerContractTests.nowUTC)
    }
  }

  /// Answers the binding confirmation and the window-inventory template with
  /// fixed receipts, and records every action it is asked to run.
  private final class ScriptedHDC: RuntimeProcessDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched: [TypedProviderAction] = []
    private let templateExitStatus: Int32

    init(templateExitStatus: Int32) {
      self.templateExitStatus = templateExitStatus
    }

    var actions: [TypedProviderAction] { lock.withLock { dispatched } }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      lock.withLock { dispatched.append(plan.action) }
      switch plan.action {
      case .hdc(.observeDevice):
        return Self.receipt(
          exitStatus: 0,
          "\(DebugWindowInventoryJobRunnerContractTests.connectKey)\t\tUSB\tConnected\tlocalhost\n")
      case .hdc(.runDebugTemplate(.windowInventory)):
        return Self.receipt(exitStatus: templateExitStatus, "WindowManagerService fixture\n")
      default:
        throw RuntimeDispatchFailure.failed("unscripted action \(plan.action)")
      }
    }

    private static func receipt(exitStatus: Int32, _ text: String) -> ProviderProcessReceipt {
      ProviderProcessReceipt(
        exitStatus: exitStatus, stdout: Data(text.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    }
  }

  /// A Runtime control plane in this process, reached the way the XPC
  /// transport reaches the daemon: one request frame in, one response line
  /// out. It records every answer as the Runtime gave it, and can withhold one
  /// member of the Job status `job.show` answers.
  private actor InProcessRuntime {
    struct Answer {
      let method: String
      let result: [String: JSONValue]
    }

    nonisolated let hdc: ScriptedHDC
    private let handler: RuntimeControlPlaneHandler
    private let withheldStatusMember: String?
    private var recorded: [Answer] = []

    init(hdc: ScriptedHDC, handler: RuntimeControlPlaneHandler, withholding member: String?) {
      self.hdc = hdc
      self.handler = handler
      withheldStatusMember = member
    }

    func answers() -> [Answer] { recorded }

    func request(
      _ method: String, _ params: [String: JSONValue]?
    ) async -> Result<Data, DebugXPCReadFailure> {
      do {
        let frame = try ArkDeckAgentXPC.requestFrame(
          method: method, params: params, requestID: "window-inventory-\(recorded.count)")
        let line = await handler.handleLine(frame)
        let response = try JSONDecoder().decode(
          JSONValue.self, from: line.last == 0x0A ? line.dropLast() : line)
        guard case .object(var envelope) = response, case .object(var result)? = envelope["result"]
        else { return .success(line) }
        recorded.append(Answer(method: method, result: result))
        guard method == "job.show", let member = withheldStatusMember,
          case .object(var job)? = result["job"]
        else { return .success(line) }
        job.removeValue(forKey: member)
        result["job"] = .object(job)
        envelope["result"] = .object(result)
        return .success(
          try CanonicalJSONEncoders.canonical().encode(JSONValue.object(envelope))
            + Data("\n".utf8))
      } catch {
        return .failure(.transport(String(describing: error)))
      }
    }
  }

  private func makeRuntime(
    templateExitStatus: Int32, withholding member: String? = nil
  ) throws -> InProcessRuntime {
    let directory = stateDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: directory.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifacts = try RuntimeArtifactStore(
      rootURL: directory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { Self.nowUTC })
    let hdc = ScriptedHDC(templateExitStatus: templateExitStatus)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: directory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: FactsPort())
      ]),
      dispatcher: hdc,
      capabilityStore: capabilities,
      artifactStore: artifacts,
      nowUTC: { Self.nowUTC })
    return InProcessRuntime(
      hdc: hdc,
      handler: RuntimeControlPlaneHandler(
        engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
        nowUTC: { Self.nowUTC }, artifactStore: artifacts),
      withholding: member)
  }

  /// The production Overview provider with the real runner over `runtime`.
  /// Its own reads adopt one target and answer nothing else, so the Trace and
  /// Flash rows are unknown here; this file is about the hidumper row.
  private func overview(_ runtime: InProcessRuntime) -> OverviewCapabilityProductionProvider {
    OverviewCapabilityProductionProvider(
      windowInventory: DebugWindowInventoryJobRunner(send: { await runtime.request($0, $1) }),
      request: { method, _ in
        let result: JSONValue
        switch method {
        case "operation.list":
          result = .array([])
        case "target.list":
          result = .array([
            .object([
              "targetId": .string(Self.targetID),
              "bindingRevision": .integer(Int64(Self.bindingRevision)),
            ])
          ])
        default:
          return .failure(.transport("no \(method) in this test"))
        }
        do {
          return .success(
            try CanonicalJSONEncoders.canonical().encode(
              JSONValue.object(["id": .string("overview"), "ok": .bool(true), "result": result])))
        } catch {
          return .failure(.transport(String(describing: error)))
        }
      })
  }
}
