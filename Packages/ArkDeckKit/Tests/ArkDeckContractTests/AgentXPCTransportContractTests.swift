// The XPC transport's whole job is to be narrower than the Unix socket.
// These tests pin the exact read + closed App-owned Job surface. It exposes
// no arbitrary operation or capability administration.

import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckWorkflows

final class AgentXPCTransportContractTests: XCTestCase {
  private func frame(method: String) -> Data {
    Data(
      #"{"protocolVersion":"1.0.0","id":"contract","method":"\#(method)"}"#.utf8)
  }

  private func submitFrame(
    operationID: String = "flash.dayu200",
    clientName: String = "ArkDeckApp.FlashWorkspace"
  ) throws -> Data {
    let typedRequest = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"ui-request","idempotencyKey":"ui-request-123",\
      "target":{"targetId":"target-1","expectedBindingRevision":2},\
      "operation":{"id":"\(operationID)","version":1},"inputs":{},\
      "requestedOutputs":["hardwareEvidence"],\
      "clientContext":{"clientName":"\(clientName)"}}
      """
    return try ArkDeckAgentXPC.requestFrame(
      method: "job.submit", params: ["requestJson": .string(typedRequest)],
      requestID: "contract-submit")
  }

  func testAppReadFrameDecodesAsTheDaemonWireRequest() throws {
    let frame = try ArkDeckAgentXPC.requestFrame(
      method: "job.status", params: ["jobId": .string("JOB-1")], requestID: "contract")
    let request = try JSONDecoder().decode(AgentWireProtocol.Request.self, from: frame)

    XCTAssertEqual(request.protocolVersion, AgentWireProtocol.version)
    XCTAssertEqual(request.method, "job.status")
    XCTAssertEqual(request.params, ["jobId": .string("JOB-1")])
  }

  // Stateless methods forward by exact name. Generic job names are present
  // only as gated vocabulary and never pass from a method-only frame.
  func testTheAllowlistForwardsExactlyTheAppControlPlane() {
    for method in ArkDeckAgentXPC.forwardableReadOnlyMethods
      .union(ArkDeckAgentXPC.forwardableFlashBundleMethods)
      .union(ArkDeckAgentXPC.forwardableRockchipBindingMethods)
      .union(ArkDeckAgentXPC.forwardableAutomationMethods)
    {
      XCTAssertEqual(
        AgentXPCEndpoint.admission(of: frame(method: method)), .direct(method: method),
        "\(method) is on the allowlist and must forward")
    }
    for method in ArkDeckAgentXPC.gatedAppJobMethods {
      XCTAssertNil(
        AgentXPCEndpoint.admission(of: frame(method: method)),
        "\(method) needs a typed payload or a UI-owned Job identifier")
    }
    // device.candidates sits in the read-only set as a pure discovery read:
    // it lists HDC candidates via the bootstrap's enumeration (never
    // `advance`, whose single-candidate path adopts), so it cannot create or
    // change a binding.
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableReadOnlyMethods,
      [
        "artifact.inspect", "artifact.list", "artifact.read", "debug.probe",
        "debug.template.run",
        "device.candidates", "flash.bootloader-status", "flash.prerequisites",
        "job.evidence", "job.list", "job.list-page", "job.status", "operation.list",
        "target.list", "trace.probe",
      ],
      "read-only surface drift is a control-plane decision")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableFlashBundleMethods,
      [
        "artifact.importFlashBundle.abort", "artifact.importFlashBundle.append",
        "artifact.importFlashBundle.begin", "artifact.importFlashBundle.commit",
      ],
      "widening the Flash artifact surface is forbidden")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableRockchipBindingMethods,
      ["flash.bind-current-loader"],
      "Loader binding must remain one closed Runtime-owned identity action")
    XCTAssertEqual(
      ArkDeckAgentXPC.gatedAppJobMethods, ["job.cancel", "job.run", "job.submit"],
      "generic job names must stay behind the payload and ownership gate")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableAutomationMethods,
      ["task.cancel", "task.list", "task.pause", "task.reconcile"],
      "Automation may control existing typed tasks but cannot create or widen them")
  }

  func testOnlyTheTypedFlashUISubmitAndItsJobShapeReachTheGate() throws {
    XCTAssertEqual(
      AgentXPCEndpoint.admission(of: try submitFrame()),
      .appSubmit(requestID: "contract-submit", kind: .flash))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics", clientName: "ArkDeckApp.TraceWorkspace")),
      .appSubmit(requestID: "contract-submit", kind: .trace))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics",
          clientName: "ArkDeckApp.DebugWorkspace.Logs")),
      .appSubmit(requestID: "contract-submit", kind: .debugLogs))
    XCTAssertNil(AgentXPCEndpoint.admission(of: try submitFrame(operationID: "debug.app")))

    let run = try ArkDeckAgentXPC.requestFrame(
      method: "job.run", params: ["jobId": .string("JOB-FLASH-1")], requestID: "run")
    XCTAssertEqual(
      AgentXPCEndpoint.admission(of: run), .appRun(jobID: "JOB-FLASH-1"))
    let cancel = try ArkDeckAgentXPC.requestFrame(
      method: "job.cancel", params: ["jobId": .string("JOB-FLASH-1")], requestID: "cancel")
    XCTAssertEqual(
      AgentXPCEndpoint.admission(of: cancel), .appCancel(jobID: "JOB-FLASH-1"))

    let injected = try ArkDeckAgentXPC.requestFrame(
      method: "job.submit",
      params: [
        "requestJson": .string(
          String(data: try submitFrame(), encoding: .utf8) ?? ""),
        "unexpected": .bool(true),
      ], requestID: "injected")
    XCTAssertNil(AgentXPCEndpoint.admission(of: injected))
  }

  func testOnlySuccessfulMatchingSubmitResponseCreatesAJobBinding() {
    let response = Data(
      #"{"id":"contract-submit","ok":true,"result":{"jobId":"JOB-FLASH-1"}}"#.utf8)
    XCTAssertEqual(
      AgentXPCEndpoint.successfulSubmittedJobID(
        in: response, requestID: "contract-submit"),
      "JOB-FLASH-1")
    XCTAssertNil(
      AgentXPCEndpoint.successfulSubmittedJobID(in: response, requestID: "another-request"))
    XCTAssertNil(
      AgentXPCEndpoint.successfulSubmittedJobID(
        in: Data(#"{"id":"contract-submit","ok":false}"#.utf8),
        requestID: "contract-submit"))
  }

  func testAppJobBindingPermitsOneRunAndOwnsCancellationUntilFinish() async {
    let gate = AgentXPCAppJobGate()
    let beforeRecord = await gate.beginRun("JOB-FLASH-1")
    XCTAssertFalse(beforeRecord)
    await gate.record("JOB-FLASH-1", kind: .flash)
    let ownsQueued = await gate.owns("JOB-FLASH-1")
    XCTAssertTrue(ownsQueued)
    let firstRun = await gate.beginRun("JOB-FLASH-1")
    let ownsRunning = await gate.owns("JOB-FLASH-1")
    XCTAssertTrue(ownsRunning)
    let replay = await gate.beginRun("JOB-FLASH-1")
    XCTAssertTrue(firstRun)
    XCTAssertFalse(replay)
    await gate.finish("JOB-FLASH-1")
    let ownsFinished = await gate.owns("JOB-FLASH-1")
    XCTAssertFalse(ownsFinished)
  }

  // The load-bearing assertion: no generic mutation, target, capability or
  // path-based Artifact surface crosses the App transport.
  func testEveryNonFlashMutationMethodIsRefusedBeforeTheHandler() {
    for method in [
      "job.reconcile", "job.plan",
      "target.adopt", "artifact.export",
      "artifact.importHap.begin", "artifact.importHap.append",
      "artifact.importHap.commit", "artifact.importHap.abort",
      "artifact.importNativeLibrary.begin", "artifact.importNativeLibrary.commit",
      "capability.draft", "capability.install", "capability.revoke",
    ] {
      XCTAssertNil(
        AgentXPCEndpoint.admission(of: frame(method: method)),
        "\(method) must never cross the sandboxed App transport")
      XCTAssertEqual(
        AgentXPCEndpoint.refusal(for: frame(method: method)), .methodNotAllowlisted)
    }
  }

  // Fail closed on anything that is not a recognisable allowlisted request:
  // an unknown method, a method added to the daemon after this build, and a
  // frame that does not parse at all.
  func testUnknownAndMalformedFramesFailClosed() {
    XCTAssertNil(AgentXPCEndpoint.admission(of: frame(method: "job.somethingNew")))
    XCTAssertEqual(
      AgentXPCEndpoint.refusal(for: frame(method: "job.somethingNew")), .methodNotAllowlisted)

    for malformed in [Data(), Data("not json".utf8), Data(#"{"v":1}"#.utf8), Data("[]".utf8)] {
      XCTAssertNil(AgentXPCEndpoint.admission(of: malformed))
      XCTAssertEqual(AgentXPCEndpoint.refusal(for: malformed), .malformedRequestFrame)
    }
  }

  // The service name is duplicated across three artifacts that cannot import
  // each other. If they drift, the lookup fails closed at runtime with no
  // compile-time signal, so the drift is caught here instead.
  func testTheMachServiceNameAgreesAcrossTheAppEntitlementAndLaunchAgent() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let name = ArkDeckAgentXPC.machServiceName
    XCTAssertEqual(name, "com.arkdeck.agentd")

    let entitlements = try String(
      contentsOf: root.appending(path: "ArkDeckApp/ArkDeckApp.entitlements"), encoding: .utf8)
    XCTAssertTrue(
      entitlements.contains("com.apple.security.temporary-exception.mach-lookup.global-name"),
      "the sandboxed App cannot look up the service without this exception")
    XCTAssertTrue(
      entitlements.contains("<string>\(name)</string>"),
      "the App's mach-lookup exception must name the exact vended service")

    let launchAgent = try String(
      contentsOf: root.appending(path: "Packages/ArkDeckKit/LaunchAgents/com.arkdeck.agentd.plist"),
      encoding: .utf8)
    XCTAssertTrue(
      launchAgent.contains("<key>\(name)</key>"),
      "the LaunchAgent must vend the exact service the App looks up")
  }
}
