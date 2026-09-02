// The XPC transport's whole job is to be narrower than the Unix socket.
// These tests pin the exact read + closed App-owned Job surface. It exposes
// no arbitrary operation or capability administration.

import ArkDeckCore
import Foundation
import XCTest
import os

@testable import ArkDeckAgentDaemon
@testable import ArkDeckWorkflows

final class AgentXPCTransportContractTests: XCTestCase {
  func testSharedTransportBoundsASilentEndpointWithoutClaimingRejection() async {
    let startedAt = ContinuousClock.now
    let result = await RuntimeXPCRequestTransport.awaitReply(timeoutSeconds: 0.01) { _ in
      // Reproduces a live endpoint that never invokes its reply closure.
    }

    XCTAssertEqual(result, .failure(.timedOut))
    XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    XCTAssertFalse(RuntimeXPCRequestTransport.Failure.timedOut.message.contains("retry"))
    XCTAssertTrue(RuntimeXPCRequestTransport.Failure.timedOut.message.contains("may already"))
  }

  func testSharedTransportUsesTheFirstTerminalSignalAndCleansUpOnce() async {
    let cleanupCount = OSAllocatedUnfairLock(initialState: 0)
    let expected = Data("first".utf8)
    let result = await RuntimeXPCRequestTransport.awaitReply(
      timeoutSeconds: 0.01,
      cleanup: { cleanupCount.withLock { $0 += 1 } },
      start: { finish in
        finish(.success(expected))
        finish(.failure(.emptyResponse))
      })

    XCTAssertEqual(result, .success(expected))
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(cleanupCount.withLock { $0 }, 1)
  }

  private func frame(method: String) -> Data {
    Data(
      #"{"protocolVersion":"1.0.0","id":"contract","method":"\#(method)"}"#.utf8)
  }

  private func targetFrame(method: String) throws -> Data {
    try ArkDeckAgentXPC.requestFrame(
      method: method, requestID: "contract-target",
      protocolVersion: ArkDeckControlProtocol.targetVersion)
  }

  private func submitFrame(
    operationID: String = "flash.dayu200",
    operationVersion: Int? = nil,
    clientName: String = ArkDeckAgentClientName.flashWorkspace
  ) throws -> Data {
    let operationJSON =
      operationVersion.map {
        #"{"id":"\#(operationID)","version":\#($0)}"#
      } ?? #"{"id":"\#(operationID)"}"#
    let typedRequest = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"ui-request","idempotencyKey":"ui-request-123",\
      "target":{"targetId":"target-1","expectedBindingRevision":2},\
      "operation":\(operationJSON),"inputs":{},\
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

  func testTargetFramesRequireAPublishedTargetMethodAndStayAllowlisted() throws {
    XCTAssertEqual(
      AgentXPCEndpoint.admission(of: try targetFrame(method: "trace.cache.status")),
      .direct(method: "trace.cache.status"))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(of: try targetFrame(method: "trace.cache.purge")),
      .direct(method: "trace.cache.purge"))
    XCTAssertNil(AgentXPCEndpoint.admission(of: try targetFrame(method: "trace.probe")))
    XCTAssertNil(AgentXPCEndpoint.admission(of: try targetFrame(method: "not.published")))
  }

  // Stateless methods forward by exact name. Generic job names are present
  // only as gated vocabulary and never pass from a method-only frame.
  func testTheAllowlistForwardsExactlyTheAppControlPlane() {
    for method in ArkDeckAgentXPC.forwardableReadOnlyMethods
      .union(ArkDeckAgentXPC.forwardableFlashBundleMethods)
      .union(ArkDeckAgentXPC.forwardableHAPImportMethods)
      .union(ArkDeckAgentXPC.forwardableNativeLibraryImportMethods)
      .union(ArkDeckAgentXPC.forwardableRockchipBindingMethods)
      .union(ArkDeckAgentXPC.forwardableHistoryFilterMethods)
      .union(ArkDeckAgentXPC.forwardableTraceCacheMethods)
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
        // artifact.quota reports headroom and nothing else: no job, no
        // identifier, no bytes. It is here so a workspace can be refused
        // before it starts work rather than after (TASK-IDC-002).
        "artifact.inspect", "artifact.list", "artifact.quota", "artifact.read",
        "debug.probe",
        // flash.lanePlanPreview is read-only by contract (CHG-2026-068
        // LPP-AC-1): exactly inspect/discover/materialize on the daemon,
        // no import, no permit, nothing durable.
        "device.candidates", "flash.bootloader-status", "flash.device-access", "flash.lanePlanPreview",
        "flash.prerequisites",
        "history.filter.list",
        "job.evidence", "job.list", "job.list-page", "job.status", "operation.list",
        "runtime.hdc-status", "runtime.storage.status", "target.list", "trace.probe",
        "trace.cache.status",
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
      ArkDeckAgentXPC.forwardableHAPImportMethods,
      [
        "artifact.importHap.abort", "artifact.importHap.append",
        "artifact.importHap.begin", "artifact.importHap.commit",
      ],
      "HAP upload must remain the four closed ID-and-chunk methods")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableNativeLibraryImportMethods,
      [
        "artifact.importNativeLibrary.abort", "artifact.importNativeLibrary.append",
        "artifact.importNativeLibrary.begin", "artifact.importNativeLibrary.commit",
      ],
      "native-library upload must remain the four closed ID-and-chunk methods")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableRockchipBindingMethods,
      ["flash.bind-current-loader"],
      "Loader binding must remain one closed Runtime-owned identity action")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableHistoryFilterMethods,
      ["history.filter.delete", "history.filter.save"],
      "History may mutate only its bounded local saved-query resource")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableTraceCacheMethods,
      ["trace.cache.purge"],
      "Trace may mutate only inactive derived databases through the fixed Runtime owner")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableRuntimeStorageMethods,
      ["runtime.storage.policy", "runtime.storage.root"],
      "Settings may mutate only the generation-bound Runtime storage resource")
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableSessionMethods,
      ["session.cleanup.apply", "session.cleanup.preview", "session.export.apply",
        "session.export.preview", "session.list", "session.pin", "session.show",
        "session.unpin"],
      "Session access must remain on the closed Runtime catalog owner")
    XCTAssertEqual(
      ArkDeckAgentXPC.gatedAppJobMethods, ["job.cancel", "job.run", "job.submit"],
      "generic job names must stay behind the payload and ownership gate")
    for removed in ["task.cancel", "task.list", "task.pause", "task.reconcile", "task.submit"] {
      XCTAssertNotEqual(
        AgentXPCEndpoint.admission(of: frame(method: removed)), .direct(method: removed),
        "the in-process task plane was removed by CHG-2026-064; \(removed) must not forward")
    }
  }

  func testRuntimeStorageXPCFramesHaveClosedTypedParameters() throws {
    func admission(
      _ method: String, _ params: [String: JSONValue]? = nil
    ) throws -> AgentXPCEndpoint.Admission? {
      AgentXPCEndpoint.admission(
        of: try ArkDeckAgentXPC.requestFrame(
          method: method, params: params, requestID: "storage-contract",
          protocolVersion: ArkDeckControlProtocol.targetVersion))
    }

    XCTAssertEqual(
      try admission("runtime.storage.status"), .direct(method: "runtime.storage.status"))
    XCTAssertNil(try admission("runtime.storage.status", ["path": .string("/tmp")]))
    XCTAssertEqual(
      try admission("runtime.storage.policy", [
        "expectedGeneration": .string("1"),
        "totalQuotaBytes": .string("10000"),
        "safetyMarginBytes": .string("1000"),
        "retentionDays": .string("7"),
      ]),
      .direct(method: "runtime.storage.policy"))
    XCTAssertNil(
      try admission("runtime.storage.policy", [
        "expectedGeneration": .string("01"),
        "totalQuotaBytes": .string("10000"),
        "safetyMarginBytes": .string("1000"),
        "retentionDays": .string("7"),
      ]))
    XCTAssertEqual(
      try admission("runtime.storage.root", [
        "expectedGeneration": .string("2"), "rootPath": .string("/tmp/sessions"),
      ]),
      .direct(method: "runtime.storage.root"))
    XCTAssertEqual(
      try admission("runtime.storage.root", [
        "expectedGeneration": .string("2"), "resetToDefault": .bool(true),
      ]),
      .direct(method: "runtime.storage.root"))
    XCTAssertNil(
      try admission("runtime.storage.root", [
        "expectedGeneration": .string("2"), "rootPath": .string("relative"),
      ]))
    XCTAssertNil(
      try admission("runtime.storage.root", [
        "expectedGeneration": .string("2"), "rootPath": .string("/tmp/sessions"),
        "resetToDefault": .bool(true),
      ]))
  }

  func testSessionXPCFramesHaveClosedTypedParameters() throws {
    func admission(
      _ method: String, _ params: [String: JSONValue]? = nil
    ) throws -> AgentXPCEndpoint.Admission? {
      AgentXPCEndpoint.admission(
        of: try ArkDeckAgentXPC.requestFrame(
          method: method, params: params, requestID: "session-contract",
          protocolVersion: ArkDeckControlProtocol.targetVersion))
    }

    XCTAssertEqual(
      try admission("session.cleanup.preview"),
      .direct(method: "session.cleanup.preview"))
    XCTAssertNil(
      try admission("session.cleanup.preview", ["confirm": .bool(true)]))
    let cleanupID = "abcdefab-cdef-4abc-8abc-abcdefabcdef"
    let cleanupDigest = String(repeating: "a", count: 64)
    XCTAssertEqual(
      try admission("session.cleanup.apply", [
        "previewId": .string(cleanupID), "previewDigest": .string(cleanupDigest),
      ]),
      .direct(method: "session.cleanup.apply"))
    XCTAssertNil(
      try admission("session.cleanup.apply", [
        "previewId": .string(cleanupID.uppercased()),
        "previewDigest": .string(cleanupDigest),
      ]))
    XCTAssertNil(
      try admission("session.cleanup.apply", [
        "previewId": .string(cleanupID), "previewDigest": .string(cleanupDigest),
        "confirmation": .string("yes"),
      ]))

    XCTAssertEqual(
      try admission("session.export.preview", [
        "sessionId": .string("session-1"),
        "destinationPath": .string("/private/tmp/session-1-export"),
        "allowSensitive": .bool(false),
      ]),
      .direct(method: "session.export.preview"))
    XCTAssertNil(
      try admission("session.export.preview", [
        "sessionId": .string("session-1"),
        "destinationPath": .string("relative/export"),
        "allowSensitive": .bool(false),
      ]),
      "the destination must be an absolute host path")
    XCTAssertNil(
      try admission("session.export.preview", [
        "sessionId": .string("session-1"),
        "destinationPath": .string("/private/tmp/session-1-export"),
      ]),
      "the privacy choice is part of the closed preview vocabulary")
    XCTAssertNil(
      try admission("session.export.preview", [
        "sessionId": .string("session-1"),
        "destinationPath": .string("/private/tmp/session-1-export"),
        "allowSensitive": .bool(true), "overwrite": .bool(true),
      ]))
    XCTAssertEqual(
      try admission("session.export.apply", [
        "previewId": .string(cleanupID), "previewDigest": .string(cleanupDigest),
      ]),
      .direct(method: "session.export.apply"))
    XCTAssertNil(
      try admission("session.export.apply", [
        "previewId": .string(cleanupID), "previewDigest": .string(cleanupDigest),
        "destinationPath": .string("/private/tmp/session-1-export"),
      ]),
      "apply publishes the exact preview; it accepts no destination of its own")

    XCTAssertEqual(try admission("session.list"), .direct(method: "session.list"))
    XCTAssertEqual(
      try admission("session.list", [
        "pageSize": .integer(10), "cursor": .string("opaque"),
      ]),
      .direct(method: "session.list"))
    XCTAssertNil(try admission("session.list", ["pageSize": .integer(0)]))
    XCTAssertEqual(
      try admission("session.show", ["sessionId": .string("session-1")]),
      .direct(method: "session.show"))
    XCTAssertNil(try admission("session.show", ["sessionId": .string("../session")]))
    XCTAssertEqual(
      try admission("session.pin", [
        "sessionId": .string("session-1"), "expectedGeneration": .string("0"),
      ]),
      .direct(method: "session.pin"))
    XCTAssertEqual(
      try admission("session.unpin", [
        "sessionId": .string("session-1"), "expectedGeneration": .string("12"),
      ]),
      .direct(method: "session.unpin"))
    XCTAssertNil(
      try admission("session.pin", [
        "sessionId": .string("session-1"), "expectedGeneration": .string("01"),
      ]))
    XCTAssertNil(
      try admission("session.pin", [
        "sessionId": .string("session-1"), "expectedGeneration": .string("0"),
        "rootPath": .string("/tmp"),
      ]))
  }

  func testOnlyPublishedTypedAppSubmitsAndTheirJobShapeReachTheGate() throws {
    XCTAssertEqual(
      AgentXPCEndpoint.admission(of: try submitFrame()),
      .appSubmit(requestID: "contract-submit", kind: .flash))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics", operationVersion: 1,
          clientName: ArkDeckAgentClientName.traceWorkspace)),
      .appSubmit(requestID: "contract-submit", kind: .trace))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics",
          operationVersion: 1,
          clientName: ArkDeckAgentClientName.debugLogsWorkspace)),
      .appSubmit(requestID: "contract-submit", kind: .debugLogs))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "debug.hap",
          operationVersion: 1,
          clientName: ArkDeckAgentClientName.debugAppsWorkspace)),
      .appSubmit(requestID: "contract-submit", kind: .debugHAP))
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "debug.template",
          operationVersion: 1,
          clientName: ArkDeckAgentClientName.debugCommandsWorkspace)),
      .appSubmit(requestID: "contract-submit", kind: .debugTemplate))
    XCTAssertNil(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "debug.template",
          operationVersion: 1,
          clientName: ArkDeckAgentClientName.debugNetworkWorkspace)))
    XCTAssertNil(
      AgentXPCEndpoint.admission(of: frame(method: "debug.template.run")),
      "the App must execute templates only through its typed Job gate")
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "deploy.native-library.app-owned",
          operationVersion: 1,
          clientName: ArkDeckAgentClientName.debugArtifactsWorkspace)),
      .appSubmit(requestID: "contract-submit", kind: .debugNativeLibrary))
    for operationID in ["port-forward.create", "port-forward.remove"] {
      XCTAssertEqual(
        AgentXPCEndpoint.admission(
          of: try submitFrame(
            operationID: operationID,
            operationVersion: 1,
            clientName: ArkDeckAgentClientName.debugNetworkWorkspace)),
        .appSubmit(requestID: "contract-submit", kind: .debugPorts))
    }
    XCTAssertEqual(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics",
          operationVersion: 1,
          clientName: ArkDeckAgentClientName.deviceControl)),
      .appSubmit(requestID: "contract-submit", kind: .deviceScreenshot))
    for operationID in ["input.tap", "input.long-press", "input.swipe"] {
      XCTAssertEqual(
        AgentXPCEndpoint.admission(
          of: try submitFrame(
            operationID: operationID,
            operationVersion: 1,
            clientName: ArkDeckAgentClientName.deviceControl)),
        .appSubmit(requestID: "contract-submit", kind: .deviceInput))
      // A gesture is admitted for the Device client and no other: the pair
      // is the subject, so the same operation from another workspace's client
      // is not an App submission at all.
      XCTAssertNil(
        AgentXPCEndpoint.admission(
          of: try submitFrame(
            operationID: operationID,
            operationVersion: 1,
            clientName: ArkDeckAgentClientName.debugNetworkWorkspace)))
    }
    XCTAssertNil(
      AgentXPCEndpoint.admission(
        of: try submitFrame(operationVersion: 1)),
      "the singleton Flash reference must not regress to a versioned request")
    XCTAssertNil(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics", clientName: ArkDeckAgentClientName.traceWorkspace)),
      "versioned App operations must not omit their published version")
    XCTAssertNil(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "capture.diagnostics", operationVersion: 2,
          clientName: ArkDeckAgentClientName.traceWorkspace)),
      "versioned App operations must remain pinned to their exact published version")
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

  func testDeviceRecordingRequestReachesTheExactPublishedAppGate() throws {
    let request = try DeviceControlFacade.recordingRequest(
      frameCount: 40,
      target: DeviceTargetPresentation(id: "target-1", bindingRevision: 2, displayName: "Fixture"),
      nonce: "xpc-recording-contract")
    let requestJSON = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
    for method in ["job.plan", "job.submit"] {
      let wire = try ArkDeckAgentXPC.requestFrame(
        method: method, params: ["requestJson": .string(requestJSON)], requestID: "record")
      XCTAssertNotNil(
        AgentXPCEndpoint.admission(of: wire),
        "the production recording request must reach Runtime admission through XPC")
    }
    for version: Int? in [nil, 0, 2] {
      XCTAssertNil(AgentXPCEndpoint.admission(of: try submitFrame(
        operationID: "capture.screen-sequence", operationVersion: version,
        clientName: ArkDeckAgentClientName.deviceControl)))
    }
    XCTAssertNil(AgentXPCEndpoint.admission(of: try submitFrame(
      operationID: "capture.screen-sequence", operationVersion: 1,
      clientName: ArkDeckAgentClientName.debugNetworkWorkspace)))
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
  func testEveryUnpublishedMutationMethodIsRefusedBeforeTheHandler() {
    for method in [
      "job.reconcile", "job.plan",
      "target.adopt", "artifact.export",
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
    let root = URL(filePath: #filePath)
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
