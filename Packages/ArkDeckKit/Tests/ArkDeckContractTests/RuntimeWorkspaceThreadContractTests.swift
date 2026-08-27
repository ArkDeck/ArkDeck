// What a run-grouping thread may and may not do.
//
// The whole value of the label is that History can say "these runs were one
// piece of work, continue here". The whole danger is that a label which
// travels with every submit quietly becomes an input to something that
// decides. These pin both halves: the thread survives the request document and
// reaches History, and it changes nothing at the admission gate.

import ArkDeckCore
import ArkDeckRuntime
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckWorkflows

final class RuntimeWorkspaceThreadContractTests: XCTestCase {
  private let saltA = "salt-a"
  private let saltB = "salt-b"

  private func request(
    clientContext: RuntimeClientContext?
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "thread-contract",
      idempotencyKey: "thread-contract-1",
      target: DurableTargetReference(targetID: "target-1", expectedBindingRevision: 2),
      operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
      inputs: [:],
      requestedOutputs: [.hardwareEvidence],
      clientContext: clientContext)
  }

  /// A thread is one workspace working on one target. It has to stay put while
  /// that is true — otherwise consecutive captures never group — and it has to
  /// move the moment either half changes, or two unrelated pieces of work get
  /// presented as one line the operator can "continue".
  func testAThreadHoldsForOneWorkspaceAndTargetAndMovesWhenEitherChanges() {
    let base = RuntimeWorkspaceThread.identifier(
      clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-1", salt: saltA)

    XCTAssertEqual(
      base,
      RuntimeWorkspaceThread.identifier(
        clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-1", salt: saltA))
    XCTAssertNotEqual(
      base,
      RuntimeWorkspaceThread.identifier(
        clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-2", salt: saltA))
    XCTAssertNotEqual(
      base,
      RuntimeWorkspaceThread.identifier(
        clientName: ArkDeckAgentClientName.debugLogsWorkspace, targetID: "target-1",
        salt: saltA))
    // A second App launch is not a continuation of the first: nobody said so.
    XCTAssertNotEqual(
      base,
      RuntimeWorkspaceThread.identifier(
        clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-1", salt: saltB))

    XCTAssertEqual(
      base.range(of: #"^t-[0-9a-f]{12}$"#, options: .regularExpression),
      base.startIndex..<base.endIndex,
      "a thread must be renderable and wire-legal: \(base)")
  }

  /// Continuing a line replays a recorded id. It cannot be conjured: a run
  /// that recorded no thread stays ungrouped rather than being adopted into
  /// some other line.
  func testContinuingReplaysARecordedThreadAndNeverInventsOne() {
    let minted = RuntimeWorkspaceThread.clientContext(
      clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-1", salt: saltA)
    XCTAssertEqual(
      minted.threadID,
      RuntimeWorkspaceThread.identifier(
        clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-1", salt: saltA))

    let continued = RuntimeWorkspaceThread.clientContext(
      clientName: ArkDeckAgentClientName.traceWorkspace,
      targetID: "target-9",
      continuing: "t-0123456789ab",
      salt: saltB)
    XCTAssertEqual(
      continued.threadID, "t-0123456789ab",
      "continuing a line must win over the target-derived default")

    XCTAssertNil(
      RuntimeWorkspaceThread.identifier(
        of: RuntimeClientContext(clientName: ArkDeckAgentClientName.traceWorkspace)))
    XCTAssertNil(RuntimeWorkspaceThread.identifier(of: nil))
  }

  /// Other provenance is the caller's; the reserved key is not. A caller that
  /// hands in both cannot end up with a request whose typed thread and wire
  /// thread disagree.
  func testTheReservedKeyWinsAndOtherProvenanceSurvives() {
    let context = RuntimeClientContext(
      clientName: ArkDeckAgentClientName.traceWorkspace,
      threadID: "t-abcdef012345",
      provenance: [
        RuntimeClientContext.threadProvenanceKey: "t-forged",
        "note": "kept",
      ])

    XCTAssertEqual(context.threadID, "t-abcdef012345")
    XCTAssertEqual(context.provenance?["note"], "kept")
  }

  /// The label has to survive the exact document the daemon receives, under a
  /// pinned wire key — History reads that key, so it is part of the contract.
  func testTheThreadSurvivesTheRequestDocumentUnderAPinnedWireKey() throws {
    let context = RuntimeWorkspaceThread.clientContext(
      clientName: ArkDeckAgentClientName.traceWorkspace, targetID: "target-1", salt: saltA)
    let encoded = try CanonicalJSONEncoders.canonical().encode(request(clientContext: context))

    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let clientContext = try XCTUnwrap(object["clientContext"] as? [String: Any])
    let provenance = try XCTUnwrap(clientContext["provenance"] as? [String: String])
    XCTAssertEqual(provenance["arkdeck.threadId"], context.threadID)

    let decoded = try JSONDecoder().decode(RuntimeOperationRequest.self, from: encoded)
    XCTAssertEqual(decoded.clientContext?.threadID, context.threadID)
  }

  /// A decoded request is the untrusted shape. A thread that could not be
  /// rendered or compared is refused there rather than reaching History as an
  /// un-groupable grouping key.
  func testAMalformedThreadIsRefusedWhenTheRequestIsDecoded() throws {
    let rejected = [
      "", "has space", "-leading", "t/../escape", "t\nnewline",
      String(repeating: "t", count: 65),
    ]
    for thread in rejected {
      let json = """
        {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
        "requestId":"thread-contract","idempotencyKey":"thread-contract-1",\
        "target":{"targetId":"target-1","expectedBindingRevision":2},\
        "operation":{"id":"capture.diagnostics","version":1},"inputs":{},\
        "requestedOutputs":["hardwareEvidence"],\
        "clientContext":{"clientName":"trace-workspace","provenance":\
        {"arkdeck.threadId":\(encodedJSONString(thread))}}}
        """
      XCTAssertThrowsError(
        try JSONDecoder().decode(RuntimeOperationRequest.self, from: Data(json.utf8)),
        "a malformed thread must fail closed: \(thread.debugDescription)")
    }

    let accepted = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"thread-contract","idempotencyKey":"thread-contract-1",\
      "target":{"targetId":"target-1","expectedBindingRevision":2},\
      "operation":{"id":"capture.diagnostics","version":1},"inputs":{},\
      "requestedOutputs":["hardwareEvidence"],\
      "clientContext":{"clientName":"trace-workspace","provenance":\
      {"arkdeck.threadId":"t-0123456789ab"}}}
      """
    XCTAssertEqual(
      try JSONDecoder().decode(
        RuntimeOperationRequest.self, from: Data(accepted.utf8)
      ).clientContext?.threadID,
      "t-0123456789ab")
  }

  /// The point of putting the thread in provenance: the gate must classify a
  /// submission identically with and without it. If these ever diverge, the
  /// label has become authority.
  func testTheThreadChangesNothingAtTheAdmissionGate() throws {
    let cases: [(operationID: String, clientName: String)] = [
      ("capture.diagnostics", ArkDeckAgentClientName.traceWorkspace),
      ("capture.diagnostics", ArkDeckAgentClientName.debugLogsWorkspace),
      ("debug.hap", ArkDeckAgentClientName.debugAppsWorkspace),
      ("port-forward.create", ArkDeckAgentClientName.debugNetworkWorkspace),
      ("input.tap", ArkDeckAgentClientName.deviceControl),
    ]
    for (operationID, clientName) in cases {
      let without = AgentXPCEndpoint.admission(
        of: try submitFrame(operationID: operationID, clientName: clientName, threadID: nil))
      let with = AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: operationID, clientName: clientName, threadID: "t-0123456789ab"))
      XCTAssertNotNil(without, "\(operationID)/\(clientName) must be admitted at all")
      XCTAssertEqual(
        with, without,
        "the thread label must not move \(operationID)/\(clientName) at the gate")
    }

    // And it cannot buy admission for a pair the gate refuses.
    XCTAssertNil(
      AgentXPCEndpoint.admission(
        of: try submitFrame(
          operationID: "input.tap",
          clientName: ArkDeckAgentClientName.debugNetworkWorkspace,
          threadID: "t-0123456789ab")))
  }

  /// History groups by the thread, and says nothing when a Job has none —
  /// records written before workspaces declared a thread must read as
  /// ungrouped, not as one shared line.
  func testHistoryProjectsTheThreadAndLeavesOlderJobsUngrouped() throws {
    func entry(_ jobID: String, thread: String?) -> [String: Any] {
      var value: [String: Any] = [
        "jobId": jobID, "operation": "capture.diagnostics@1", "targetId": "target-1",
        "state": "succeeded",
      ]
      if let thread { value["threadId"] = thread }
      return value
    }
    let data = try JSONSerialization.data(
      withJSONObject: [
        "ok": true, "id": "x",
        "result": [
          entry("job-1", thread: "t-0123456789ab"),
          entry("job-2", thread: "t-0123456789ab"),
          entry("job-3", thread: nil),
        ],
      ])

    let presentation = RuntimeHistoryResponseDecoding.presentation(from: data)
    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(
      presentation.jobs.map(\.threadID), ["t-0123456789ab", "t-0123456789ab", nil])
  }

  private func encodedJSONString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(text.dropFirst().dropLast())
  }

  private func submitFrame(
    operationID: String,
    clientName: String,
    threadID: String?
  ) throws -> Data {
    let provenance = threadID.map { #","provenance":{"arkdeck.threadId":"\#($0)"}"# } ?? ""
    let typedRequest = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"ui-request","idempotencyKey":"ui-request-123",\
      "target":{"targetId":"target-1","expectedBindingRevision":2},\
      "operation":{"id":"\(operationID)","version":1},"inputs":{},\
      "requestedOutputs":["hardwareEvidence"],\
      "clientContext":{"clientName":"\(clientName)"\(provenance)}}
      """
    return try ArkDeckAgentXPC.requestFrame(
      method: "job.submit", params: ["requestJson": .string(typedRequest)],
      requestID: "contract-submit")
  }
}
