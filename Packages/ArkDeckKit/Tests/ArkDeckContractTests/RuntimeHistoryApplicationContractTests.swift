// What the App is allowed to conclude from a daemon answer.
//
// The dangerous failure for a read-only history surface is not a crash, it is
// a confident wrong reading: showing an empty, calm history when the truth is
// "could not read it", or folding an unknown outcome into a terminal state.
// These pin against exactly that.

import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeHistoryApplicationContractTests: XCTestCase {
  private func decode(_ json: String) -> RuntimeHistoryPresentation {
    RuntimeHistoryResponseDecoding.presentation(from: Data(json.utf8))
  }

  private func reason(_ presentation: RuntimeHistoryPresentation) -> String? {
    guard case .unavailable(let reason) = presentation.availability else { return nil }
    return reason
  }

  private func response(_ result: Any) throws -> RuntimeHistoryTransportResult {
    .success(
      try JSONSerialization.data(
        withJSONObject: ["ok": true, "id": "history-contract", "result": result]))
  }

  private func previewArtifact(
    _ bytes: Data, privacy: String = "standard", status: String = "published", hash: String? = nil
  ) -> RuntimeArtifactPresentation {
    RuntimeArtifactPresentation(
      id: "artifact-preview", name: "capture.log", role: "log", mediaType: "text/plain",
      byteCount: Int64(bytes.count), sha256: hash ?? SHA256Hex.string(of: bytes),
      privacy: privacy, status: status, statusDetail: nil, sourceOperation: "capture.diagnostics@1",
      createdAtUTC: "2026-08-27T08:00:00Z", redactionApplied: false)
  }

  private func chunk(
    _ bytes: Data, total: Int, offset: Int, eof: Bool, digest: String? = nil
  ) throws -> RuntimeHistoryTransportResult {
    try response([
      "artifactId": "artifact-preview", "artifactDigest": digest ?? SHA256Hex.string(of: bytes), "offset": offset, "nextOffset": offset + bytes.count,
      "totalByteCount": total, "byteCount": bytes.count, "base64": bytes.base64EncodedString(),
      "eof": eof,
    ])
  }

  func testBoundedPreviewReadsExactChunksAndVerifiesTheCompleteHash() async throws {
    let bytes = Data(repeating: 65, count: 300_000)
    let boundary = 256 * 1_024
    let transport = HistoryRPCScenario([
      ("artifact.read", try chunk(bytes.prefix(boundary), total: bytes.count, offset: 0, eof: false, digest: SHA256Hex.string(of: bytes))),
      ("artifact.read", try chunk(bytes.suffix(bytes.count - boundary), total: bytes.count, offset: boundary, eof: true, digest: SHA256Hex.string(of: bytes))),
    ])
    let reader = RuntimeJobDetailXPCProvider(request: { await transport.request($0, $1) })
    let result = await reader.readArtifact(
      jobID: "job-preview", artifact: previewArtifact(bytes), maximumBytes: 400_000, allowSensitive: false)
    XCTAssertEqual(result, .loaded(bytes))
    let calls = await transport.recordedCalls()
    XCTAssertEqual(calls.map(\.0), ["artifact.read", "artifact.read"])
    XCTAssertEqual(calls.map { $0.1["offset"] }, [.integer(0), .integer(Int64(boundary))])
    XCTAssertTrue(calls.allSatisfy {
      $0.1["owner"] == .object(["kind": .string("job"), "id": .string("job-preview")]) && $0.1["artifactId"] == .string("artifact-preview")
        && $0.1["maxBytes"] == .integer(Int64(boundary)) && $0.1["allowSensitive"] == .bool(false)
    })
  }

  func testPreviewPrivacyPublicationAndSizeRefusalsReadNoBytes() async {
    let bytes = Data("private".utf8)
    let transport = HistoryRPCScenario([])
    let reader = RuntimeJobDetailXPCProvider(request: { await transport.request($0, $1) })
    for (artifact, limit) in [
      (previewArtifact(bytes, privacy: "sensitive"), 100),
      (previewArtifact(bytes, privacy: "future-unknown"), 100),
      (previewArtifact(bytes, status: "missing"), 100),
      (previewArtifact(bytes), bytes.count - 1),
      (previewArtifact(bytes), 0),
      (previewArtifact(bytes), 16 * 1_024 * 1_024 + 1),
    ] {
      guard case .failed = await reader.readArtifact(
        jobID: "job-preview", artifact: artifact, maximumBytes: limit, allowSensitive: false)
      else { return XCTFail("preview bypassed its privacy or byte bound") }
    }
    let calls = await transport.recordedCalls()
    XCTAssertTrue(calls.isEmpty)
  }

  func testPreviewRejectsWrongOffsetEarlyEOFAndWrongHash() async throws {
    let bytes = Data("proof".utf8)
    let cases: [(RuntimeArtifactPresentation, RuntimeHistoryTransportResult)] = [
      (previewArtifact(bytes), try chunk(bytes, total: bytes.count, offset: 1, eof: true)),
      (previewArtifact(bytes), try chunk(bytes.prefix(1), total: bytes.count, offset: 0, eof: true)),
      (previewArtifact(bytes, hash: String(repeating: "0", count: 64)),
       try chunk(bytes, total: bytes.count, offset: 0, eof: true)),
    ]
    for (artifact, answer) in cases {
      let transport = HistoryRPCScenario([("artifact.read", answer)])
      let reader = RuntimeJobDetailXPCProvider(request: { await transport.request($0, $1) })
      guard case .failed = await reader.readArtifact(
        jobID: "job-preview", artifact: artifact, maximumBytes: 100, allowSensitive: false)
      else { return XCTFail("drifting bytes were presented as verified") }
      let calls = await transport.recordedCalls()
      XCTAssertEqual(calls.count, 1)
    }
  }

  private func cancellableJob(state: String = "running", unknown: Bool = false) -> RuntimeJobSummaryPresentation {
    RuntimeJobSummaryPresentation(
      id: "job-cancel", operationReference: "capture.diagnostics@1", targetID: "target-cancel",
      state: state, waitingForHuman: false, outcomeUnknown: unknown, outstandingResidueCount: 0,
      timeline: [], sessionID: "session-cancel", actualEffect: "readOnly")
  }

  func testGlobalCancellationUsesFreshIdentityAndOnlyRequestsTheSafeBoundary() async throws {
    let transport = HistoryRPCScenario([
      ("job.status", try response([
        "jobId": "job-cancel", "operation": "capture.diagnostics@1", "targetId": "target-cancel",
        "sessionId": "session-cancel", "state": "running", "outcomeUnknown": false,
      ])),
      ("job.cancel", try response(["cancelRequested": true])),
    ])
    let control = RuntimeJobControlXPCProvider(request: { await transport.request($0, $1) })
    let result = await control.cancel(cancellableJob())
    XCTAssertEqual(result, .requested, "acceptance must not be projected as terminal cancelled")
    let calls = await transport.recordedCalls()
    XCTAssertEqual(calls.map(\.0), ["job.status", "job.cancel"])
    XCTAssertTrue(calls.allSatisfy { $0.1 == ["jobId": .string("job-cancel")] })
  }

  func testGlobalCancellationRefusesTerminalUnknownAndDriftingJobsWithoutCancelDispatch() async throws {
    let noRead = HistoryRPCScenario([])
    let closed = RuntimeJobControlXPCProvider(request: { await noRead.request($0, $1) })
    for job in [cancellableJob(state: "succeeded"), cancellableJob(unknown: true), cancellableJob(state: "unrecognized")] {
      guard case .refused = await closed.cancel(job) else { return XCTFail("non-cancellable Job was accepted") }
    }
    let initialCalls = await noRead.recordedCalls()
    XCTAssertTrue(initialCalls.isEmpty)

    for drift: [String: Any] in [
      ["jobId": "another-job"], ["operation": "flash.dayu200@1"], ["targetId": "another-target"],
      ["sessionId": "another-session"], ["state": "succeeded"], ["outcomeUnknown": true],
    ] {
      var status: [String: Any] = [
        "jobId": "job-cancel", "operation": "capture.diagnostics@1", "targetId": "target-cancel",
        "sessionId": "session-cancel", "state": "running", "outcomeUnknown": false,
      ]
      status.merge(drift) { _, new in new }
      let transport = HistoryRPCScenario([("job.status", try response(status))])
      let control = RuntimeJobControlXPCProvider(request: { await transport.request($0, $1) })
      guard case .refused = await control.cancel(cancellableJob()) else { return XCTFail("fresh drift was accepted") }
      let calls = await transport.recordedCalls()
      XCTAssertEqual(calls.map(\.0), ["job.status"])
    }
  }

  // A complete answer is the only thing that produces an available history.
  func testACompleteJobListBecomesAvailableHistory() {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "job-1",
              "operation": "observe.devices@1",
              "targetId": "t-1",
              "state": "succeeded",
              "waitingForHuman": false,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "queued",
                  "running",
                  "succeeded"
                ]
              },
              "executionMode": "execute",
              "sessionId": "session-job-1",
              "actualEffect": "readOnly",
              "createdAtUtc": "2026-08-06T07:00:00Z",
              "startedAtUtc": "2026-08-06T07:00:01Z",
              "finishedAtUtc": "2026-08-06T07:00:02Z",
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.jobs.count, 1)
    let job = try? XCTUnwrap(presentation.jobs.first)
    XCTAssertEqual(job?.id, "job-1")
    XCTAssertEqual(job?.operationReference, "observe.devices@1")
    XCTAssertEqual(job?.targetID, "t-1")
    XCTAssertEqual(job?.state, "succeeded")
    XCTAssertEqual(job?.timeline, ["queued", "running", "succeeded"])
    XCTAssertEqual(job?.needsAttention, false)
    XCTAssertEqual(job?.executionMode, "execute")
    XCTAssertEqual(job?.sessionID, "session-job-1")
    XCTAssertEqual(job?.actualEffect, "readOnly")
    XCTAssertEqual(job?.createdAtUTC, "2026-08-06T07:00:00Z")
    XCTAssertEqual(job?.startedAtUTC, "2026-08-06T07:00:01Z")
    XCTAssertEqual(job?.finishedAtUTC, "2026-08-06T07:00:02Z")
    XCTAssertEqual(job?.requiresRecoveryGuidance, false)
  }

  func testOptionalHistoryFactsAreNotInventedWhenAbsent() throws {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "job-old",
              "operation": "observe.device@1",
              "targetId": "t-1",
              "state": "succeeded",
              "waitingForHuman": false,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "succeeded"
                ]
              },
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)

    let job = try XCTUnwrap(presentation.jobs.first)
    XCTAssertNil(job.executionMode)
    XCTAssertNil(job.sessionID)
    XCTAssertNil(job.actualEffect)
    XCTAssertNil(job.createdAtUTC)
    XCTAssertNil(job.startedAtUTC)
    XCTAssertNil(job.finishedAtUTC)
  }

  func testWorkspaceKindProjectionDistinguishesSharedDiagnosticsRequests() {
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: [
          "uiDump": .bool(true),
          "uiScreenshot": .bool(true),
          "uiComponentTree": .bool(true),
        ]),
      .viewer)
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: ["traceCategories": .array([.string("ace")])]),
      .trace)
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: [
          "uiScreenshot": .bool(true),
          "captureHilog": .bool(false),
          "crashLogs": .bool(false),
        ]),
      .device)
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: [
          "uiScreenshot": .bool(true),
          "captureHilog": .bool(true),
        ],
        clientName: ArkDeckAgentClientName.debugLogsWorkspace),
      .debug,
      "a diagnostic capture with HiLog must not become Device merely because it has a screenshot")
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1", inputs: [:]),
      .diagnostics)
  }

  func testDeviceWorkspaceReadsThePublishedHistoryNameAfterRename() throws {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "job-device",
              "operation": "input.tap@1",
              "targetId": "t-1",
              "workspaceKind": "toolkit",
              "state": "succeeded",
              "waitingForHuman": false,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "succeeded"
                ]
              },
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)
    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(try XCTUnwrap(presentation.jobs.first).workspaceKind, .device)
    XCTAssertEqual(
      String(decoding: try JSONEncoder().encode(RuntimeWorkspaceKind.device), as: UTF8.self),
      "\"toolkit\"",
      "the rename must remain readable by an existing daemon or App")
  }

  func testWorkspaceKindProjectionMapsOnlyKnownProductSurfaces() {
    let cases: [(String, RuntimeWorkspaceKind)] = [
      ("flash.dayu200@1", .flash),
      ("observe.device@1", .viewer),
      ("analyzer.analyze-trace@1", .trace),
      ("analyzer.summarize-hilog@1", .diagnostics),
      ("debug.hap@1", .debug),
      ("input.tap@1", .device),
    ]
    for (operation, expected) in cases {
      XCTAssertEqual(
        RuntimeWorkspaceKindProjection.kind(forOperation: operation, inputs: [:]),
        expected,
        operation)
    }
    XCTAssertNil(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "future.unknown@1", inputs: [:]))
    XCTAssertNil(
      RuntimeWorkspaceKindProjection.unambiguousKind(
        forOperation: "capture.diagnostics@1"),
      "an older daemon did not publish enough facts to guess a shared diagnostics origin")
  }

  func testWorkspaceKindAndUnambiguousOperationProjectCurrentSummaries() throws {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "job-viewer",
              "operation": "capture.diagnostics@1",
              "targetId": "t-1",
              "state": "succeeded",
              "workspaceKind": "viewer",
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "job-old-debug",
              "operation": "debug.hap@1",
              "targetId": "t-1",
              "state": "succeeded",
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "job-old-shared",
              "operation": "capture.diagnostics@1",
              "targetId": "t-1",
              "state": "succeeded",
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)

    XCTAssertEqual(presentation.jobs[0].workspaceKind, .viewer)
    XCTAssertEqual(presentation.jobs[0].resolvedWorkspaceKind, .viewer)
    XCTAssertNil(presentation.jobs[1].workspaceKind)
    XCTAssertEqual(presentation.jobs[1].resolvedWorkspaceKind, .debug)
    XCTAssertNil(presentation.jobs[2].resolvedWorkspaceKind)
  }

  func testLegacyDetailParametersOnlyResolveUnambiguousSharedCaptures() {
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [.init(name: "uiComponentTree", value: "true")]),
      .viewer)
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [.init(name: "traceCategories", value: "[\"ace\"]")]),
      .trace)
    XCTAssertEqual(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [
          .init(name: "uiScreenshot", value: "true"),
          .init(name: "captureHilog", value: "false"),
          .init(name: "traceCategories", value: "[]"),
        ]),
      .device)
    XCTAssertNil(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1", parameters: []))
    XCTAssertNil(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [.init(name: "captureHilog", value: "true")]),
      "the old evidence has no client provenance to separate Diagnostics and Debug")
  }

  func testHistoryWorkspaceContextCarriesExactReadOnlyRecordAndRefusesMismatches() throws {
    let job = RuntimeJobSummaryPresentation(
      id: "job-viewer", operationReference: "capture.diagnostics@1",
      targetID: "TGT-1", state: "succeeded", waitingForHuman: false,
      outcomeUnknown: false, outstandingResidueCount: 0, timeline: ["succeeded"],
      executionMode: "execute", sessionID: "session-viewer", threadID: "thread-viewer",
      workspaceKind: .viewer, finishedAtUTC: "2026-08-27T00:00:00Z")
    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: job.id,
      operationReference: job.operationReference,
      evidenceResponse: try response([
        "jobId": job.id,
        "operationReference": job.operationReference,
        "catalogDigest": String(repeating: "a", count: 64),
        "bindingRevision": 7,
        "providerId": "openharmony-hdc",
        "executionMode": "execute",
        "terminalState": "succeeded",
        "parameters": ["uiComponentTree": true],
      ]),
      artifactResponse: .success(try currentArtifactPageResponse([])))

    let context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(job: job, detail: detail))
    XCTAssertEqual(context.jobID, job.id)
    XCTAssertEqual(context.operationReference, job.operationReference)
    XCTAssertEqual(context.targetID, "TGT-1")
    XCTAssertEqual(context.bindingRevision, 7)
    XCTAssertEqual(context.executionMode, "execute")
    XCTAssertEqual(context.sessionID, "session-viewer")
    XCTAssertEqual(context.threadID, "thread-viewer")
    XCTAssertEqual(context.parameters.map(\.name), ["uiComponentTree"])

    let anotherJob = RuntimeJobSummaryPresentation(
      id: "job-other", operationReference: job.operationReference,
      targetID: job.targetID, state: job.state, waitingForHuman: false,
      outcomeUnknown: false, outstandingResidueCount: 0, timeline: [],
      workspaceKind: .viewer)
    XCTAssertNil(RuntimeHistoryWorkspaceContext(job: anotherJob, detail: detail))

    let legacyShared = RuntimeJobSummaryPresentation(
      id: job.id, operationReference: job.operationReference,
      targetID: job.targetID, state: job.state, waitingForHuman: false,
      outcomeUnknown: false, outstandingResidueCount: 0, timeline: [])
    let legacyContext = try XCTUnwrap(
      RuntimeHistoryWorkspaceContext(job: legacyShared, detail: detail))
    XCTAssertEqual(legacyContext.workspaceKind, .viewer)

    let ambiguousDetail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: job.id,
      operationReference: job.operationReference,
      evidenceResponse: try response([
        "jobId": job.id,
        "operationReference": job.operationReference,
        "catalogDigest": String(repeating: "a", count: 64),
        "bindingRevision": 7,
        "providerId": "openharmony-hdc",
        "executionMode": "execute",
        "terminalState": "succeeded",
        "parameters": ["captureHilog": true, "uiScreenshot": true],
      ]),
      artifactResponse: .success(try currentArtifactPageResponse([])))
    XCTAssertNil(
      RuntimeHistoryWorkspaceContext(job: legacyShared, detail: ambiguousDetail),
      "legacy diagnostics and Debug requests remain unknown without client provenance")
  }

  func testPagedSummaryPreservesRuntimeCurrentRowsWithoutInventingACompactTimeline() throws {
    let cursor = "11111111-1111-4111-8111-111111111111.41"
    let data = try currentJobPageResponse([
      ["jobId": "job-old-current", "operation": "flash.dayu200@1", "targetId": "TGT-1",
       "state": "waitingForRecovery", "current": true, "outcomeUnknown": true, "timeline": NSNull()],
      ["jobId": "job-newest", "operation": "observe.device@1", "targetId": "TGT-1",
       "state": "succeeded", "current": false, "timeline": NSNull()],
    ], cursor: cursor)
    switch RuntimeHistoryResponseDecoding.page(from: data) {
    case .unavailable(let reason): XCTFail("complete page must decode: \(reason)")
    case .available(let jobs, let nextCursor):
      XCTAssertEqual(jobs.map(\.id), ["job-old-current", "job-newest"])
      XCTAssertEqual(jobs.map(\.timeline), [[], []])
      XCTAssertTrue(jobs[0].requiresRecoveryGuidance)
      XCTAssertEqual(nextCursor, cursor)
    }
  }

  // The load-bearing distinction: a daemon that answered "no jobs" and a
  // daemon that could not be read must never produce the same presentation.
  func testAnEmptyHistoryIsNotTheSameAsAnUnreadableOne() {
    let empty = RuntimeHistoryResponseDecoding.presentation(from: try! currentJobPageResponse([]))
    XCTAssertEqual(empty.availability, .available)
    XCTAssertTrue(empty.jobs.isEmpty)

    for unreadable in [
      "",
      "not json",
      "[]",
      #"{"ok":true,"id":"x"}"#,
      #"{"ok":false,"id":"x"}"#,
      #"{"id":"x","result":[]}"#,
      #"{"ok":true,"id":"x","result":"nope"}"#,
    ] {
      let presentation = decode(unreadable)
      XCTAssertNotEqual(
        presentation.availability, .available,
        "an unreadable answer must never present as available history: \(unreadable)")
      XCTAssertTrue(
        presentation.jobs.isEmpty,
        "an unavailable history must carry no jobs: \(unreadable)")
    }
  }

  // A daemon error is surfaced with its own code and message rather than
  // flattened into a generic failure the user cannot act on.
  func testADaemonErrorKeepsItsCodeAndMessage() {
    let presentation = decode(
      #"{"ok":false,"id":"x","error":{"code":"malformedFrame","message":"undecodable request frame"}}"#
    )
    let reason = reason(presentation)
    XCTAssertNotNil(reason)
    XCTAssertTrue(
      reason?.contains("malformedFrame") == true, "the code must survive: \(reason ?? "")")
    XCTAssertTrue(
      reason?.contains("undecodable request frame") == true,
      "the daemon's own message must survive: \(reason ?? "")")
  }

  // A job missing an identifying fact fails the whole read rather than being
  // silently dropped: a history that quietly omits rows is worse than one
  // that says it could not be read.
  func testAJobMissingAnIdentifyingFactFailsTheWholeRead() {
    for missing in ["jobId", "operation", "targetId", "state"] {
      var entry: [String: Any] = [
        "jobId": "job-1", "operation": "observe.devices@1", "targetId": "t-1",
        "state": "succeeded",
      ]
      entry.removeValue(forKey: missing)
      let data = try? JSONSerialization.data(
        withJSONObject: ["ok": true, "id": "x", "result": [entry]])
      let presentation = RuntimeHistoryResponseDecoding.presentation(from: data ?? Data())

      XCTAssertNotEqual(
        presentation.availability, .available,
        "a job without \(missing) must not yield an available history")
      XCTAssertTrue(presentation.jobs.isEmpty, "no partial row may survive a missing \(missing)")
    }
  }

  // An unknown outcome and a waiting job are never presentable as settled.
  func testUnknownOutcomeAndHumanWaitBothRaiseNeedsAttention() {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "job-unknown",
              "operation": "flash.dayu200",
              "targetId": "t-1",
              "state": "interrupted",
              "waitingForHuman": false,
              "outcomeUnknown": true,
              "outstandingResidueCount": 2,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "queued",
                  "running",
                  "interrupted"
                ]
              },
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "job-waiting",
              "operation": "flash.dayu200",
              "targetId": "t-2",
              "state": "running",
              "waitingForHuman": true,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "queued",
                  "running"
                ]
              },
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "job-settled",
              "operation": "observe.devices@1",
              "targetId": "t-3",
              "state": "succeeded",
              "waitingForHuman": false,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "succeeded"
                ]
              },
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.jobs.map(\.needsAttention), [true, true, false])
    XCTAssertEqual(presentation.jobs.map(\.requiresRecoveryGuidance), [true, true, false])
    XCTAssertEqual(presentation.jobs.first?.outstandingResidueCount, 2)
  }

  func testRecoveryStatesRaiseGuidanceUntilRuntimeEstablishesTheCurrentEpoch() {
    for state in [
      "waitingForRecovery", "awaitingRebindConfirmation",
      "resumeAtConfirmedSafeBoundary", "userAbandonRequested",
    ] {
      let job = RuntimeJobSummaryPresentation(
        id: "job-\(state)", operationReference: "flash.dayu200", targetID: "t-1",
        state: state, waitingForHuman: false, outcomeUnknown: false,
        outstandingResidueCount: 0, timeline: [])
      XCTAssertTrue(job.requiresRecoveryGuidance, state)
    }

    let running = RuntimeJobSummaryPresentation(
      id: "job-running", operationReference: "flash.dayu200", targetID: "t-1",
      state: "running", waitingForHuman: false, outcomeUnknown: false,
      outstandingResidueCount: 0, timeline: [])
    XCTAssertFalse(running.requiresRecoveryGuidance)
    XCTAssertTrue(running.isCurrentActivity)

    let resolvedRecovery = RuntimeJobSummaryPresentation(
      id: "job-resolved-recovery", operationReference: "flash.dayu200", targetID: "t-1",
      state: "waitingForRecovery", waitingForHuman: false, outcomeUnknown: true,
      outstandingResidueCount: 0, timeline: ["running", "waitingForRecovery"],
      supersededByRecoveryEpochID: "recovery-epoch-current")
    XCTAssertTrue(resolvedRecovery.hasEstablishedCurrentEpoch)
    XCTAssertFalse(resolvedRecovery.requiresRecoveryGuidance)
    XCTAssertFalse(
      resolvedRecovery.isCurrentActivity,
      "historical unknown states remain nonterminal for audit but are not current activity")
  }

  func testTargetAliasResolutionKeepsUnknownOutcomeButSettlesCurrentEpochAttention() throws {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "job-unknown",
              "operation": "flash.dayu200",
              "targetId": "t-alias",
              "state": "waitingForRecovery",
              "waitingForHuman": false,
              "outcomeUnknown": true,
              "outstandingResidueCount": 1,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "running",
                  "waitingForRecovery"
                ]
              },
              "resolvedByTargetAliasResolutionId": "target-alias-resolution-0123456789abcdef",
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)

    let job = try XCTUnwrap(presentation.jobs.first)
    XCTAssertTrue(job.outcomeUnknown, "the historical outcome is never rewritten")
    XCTAssertEqual(
      job.resolvedByTargetAliasResolutionID,
      "target-alias-resolution-0123456789abcdef")
    XCTAssertTrue(job.hasEstablishedCurrentEpoch)
    XCTAssertFalse(
      job.needsAttention,
      "a later complete Flash established the current epoch without settling the old outcome")
    XCTAssertFalse(
      job.requiresRecoveryGuidance,
      "resolved History stays inspectable without remaining a global operator action")
  }

  func testFlashActivityUsesRecencyAfterResolvedUnknownsWithoutRewritingHistory() throws {
    let presentation = decode(
      """
      {
        "ok": true,
        "id": "x",
        "result": {
          "schemaVersion": "arkdeck.cli.page/1",
          "pageKind": "snapshot",
          "items": [
            {
              "jobId": "old-alias",
              "operation": "flash.dayu200",
              "targetId": "t-alias",
              "state": "waitingForRecovery",
              "waitingForHuman": false,
              "outcomeUnknown": true,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "waitingForRecovery"
                ]
              },
              "createdAtUtc": "2026-08-05T08:00:00Z",
              "resolvedByTargetAliasResolutionId": "target-alias-resolution-fixture",
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "old-superseded",
              "operation": "flash.dayu200",
              "targetId": "t-1",
              "state": "waitingForRecovery",
              "waitingForHuman": false,
              "outcomeUnknown": true,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "waitingForRecovery"
                ]
              },
              "createdAtUtc": "2026-08-05T09:00:00Z",
              "supersededByRecoveryEpochId": "recovery-epoch-fixture",
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "latest-observe",
              "operation": "observe.device@1",
              "targetId": "t-1",
              "state": "succeeded",
              "waitingForHuman": false,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "succeeded"
                ]
              },
              "createdAtUtc": "2026-08-06T10:00:00Z",
              "schemaVersion": "arkdeck.job-summary/1"
            },
            {
              "jobId": "latest-flash",
              "operation": "flash.full-restore@1",
              "targetId": "t-1",
              "state": "succeeded",
              "waitingForHuman": false,
              "outcomeUnknown": false,
              "outstandingResidueCount": 0,
              "timeline": {
                "kind": "inline",
                "entries": [
                  "succeeded"
                ]
              },
              "createdAtUtc": "2026-08-06T08:00:00Z",
              "finishedAtUtc": "2026-08-06T08:03:00Z",
              "schemaVersion": "arkdeck.job-summary/1"
            }
          ],
          "order": "createdAtDescJobIdAsc",
          "snapshotRevision": "11111111-1111-4111-8111-111111111111",
          "hasMore": false,
          "nextCursor": null
        }
      }
      """)
    let originalJobs = presentation.jobs
    XCTAssertEqual(presentation.focusedFlashActivity?.id, "latest-flash")
    XCTAssertEqual(
      presentation.flashActivityJobs.map(\.id), ["latest-flash", "old-superseded", "old-alias"])
    XCTAssertEqual(presentation.jobs, originalJobs, "the paged Runtime history remains untouched")
    XCTAssertTrue(presentation.jobs[0].outcomeUnknown)
    XCTAssertTrue(presentation.jobs[1].outcomeUnknown)
    XCTAssertEqual(presentation.jobs[0].state, "waitingForRecovery")
    XCTAssertEqual(presentation.jobs[1].state, "waitingForRecovery")
  }

  func testFlashActivityUnresolvedStopsOutrankNewerSuccessAndRunningJobs() {
    func job(_ id: String, state: String, unknown: Bool = false, waiting: Bool = false)
      -> RuntimeJobSummaryPresentation
    {
      RuntimeJobSummaryPresentation(
        id: id, operationReference: "flash.full-restore@1", targetID: "t-1",
        state: state, waitingForHuman: waiting, outcomeUnknown: unknown,
        outstandingResidueCount: 0, timeline: [],
        createdAtUTC: id == "success" ? "2026-08-06T10:00:00Z" : nil)
    }
    let success = job("success", state: "succeeded")
    let running = job("running", state: "running")
    let recovery = job("recovery", state: "awaitingRebindConfirmation")
    let waiting = job("waiting", state: "running", waiting: true)
    let unknown = job("unknown", state: "interrupted", unknown: true)
    for (jobs, expected) in [
      ([success, running, recovery, waiting, unknown], "unknown"),
      ([success, running, recovery, waiting], "waiting"),
      ([success, running, recovery], "recovery"),
      ([success, running], "running"),
    ] {
      XCTAssertEqual(
        RuntimeHistoryPresentation(availability: .available, jobs: jobs).focusedFlashActivity?.id,
        expected)
    }
  }

  func testFlashActivityMissingDatesAndEqualDatesHaveStableOrder() {
    let jobs = ["b", "a"].map { id in
      RuntimeJobSummaryPresentation(
        id: id, operationReference: "flash.dayu200", targetID: "t-1", state: "planned",
        waitingForHuman: false, outcomeUnknown: false, outstandingResidueCount: 0, timeline: [])
    }
    let missing = RuntimeHistoryPresentation(availability: .available, jobs: jobs)
    XCTAssertEqual(missing.flashActivityJobs.map(\.id), ["a", "b"])
    XCTAssertTrue(missing.flashActivityJobs.allSatisfy { $0.activityDate == nil })
    let dated = jobs.map { job in
      RuntimeJobSummaryPresentation(
        id: job.id, operationReference: job.operationReference, targetID: job.targetID,
        state: job.state, waitingForHuman: false, outcomeUnknown: false,
        outstandingResidueCount: 0, timeline: [], createdAtUTC: "2026-08-06T08:00:00Z")
    }
    XCTAssertEqual(
      RuntimeHistoryPresentation(availability: .available, jobs: dated).flashActivityJobs.map(\.id),
      ["a", "b"])
    XCTAssertNil(RuntimeHistoryPresentation(availability: .available, jobs: []).focusedFlashActivity)
  }

  func testCompleteEvidenceAndArtifactMetadataBecomeReadOnlyDetail() throws {
    let status = RuntimeHistoryTransportResult.success(try currentJobDetailResponse([
      "jobId": "job-1",
      "operation": "observe.device@1",
      "targetId": "target-dayu200-a",
      "sessionId": "session-job-1",
      "timeline": ["queued", "running", "succeeded"],
    ]))
    let evidence = try response([
      "jobId": "job-1",
      "operationReference": "observe.device@1",
      "catalogDigest": String(repeating: "a", count: 64),
      "bindingRevision": 7,
      "providerId": "openharmony-hdc",
      "actualEffect": "readOnly",
      "executionMode": "execute",
      "terminalState": "succeeded",
      "startedAtUtc": "2026-08-06T07:00:01Z",
      "finishedAtUtc": "2026-08-06T07:00:02Z",
      "parameters": ["includeToolFacts": true, "limit": 2],
      "actualStepKinds": ["readDeviceFacts"],
      "authority": ["kind": "defaultReadOnlyPolicy", "reference": "policy@1"],
      "observation": [
        "model": "DAYU200", "firmware": "OpenHarmony", "transport": "usb",
        "bindingRevision": 8,
      ],
      "blockers": [],
    ])
    let artifacts = RuntimeHistoryTransportResult.success(try currentArtifactPageResponse([
      [
        "artifactId": "artifact-1",
        "jobId": "job-1",
        "name": "device-facts.json",
        "mediaType": "application/json",
        "byteCount": 128,
        "sha256": String(repeating: "b", count: 64),
        "privacy": "sensitive",
        "status": "published",
        "statusDetail": NSNull(),
        "sourceOperation": "observe.device@1",
        "createdAtUtc": "2026-08-06T07:00:02Z",
        "redactionApplied": true,
      ]
    ]))

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-1",
      operationReference: "observe.device@1",
      statusResponse: status,
      evidenceResponse: evidence,
      artifactResponse: artifacts)

    XCTAssertEqual(detail.timelineAvailability, .available)
    XCTAssertEqual(detail.timeline, ["queued", "running", "succeeded"])
    XCTAssertEqual(detail.evidenceAvailability, .available)
    XCTAssertEqual(detail.evidence?.providerID, "openharmony-hdc")
    XCTAssertEqual(detail.evidence?.parameters.map(\.name), ["includeToolFacts", "limit"])
    XCTAssertEqual(detail.evidence?.parameters.map(\.value), ["true", "2"])
    XCTAssertTrue(detail.evidence?.parametersWereReported == true)
    XCTAssertEqual(detail.evidence?.typedParameters, ["includeToolFacts": .bool(true), "limit": .integer(2)])
    XCTAssertEqual(detail.evidence?.observedBindingRevision, 8)
    XCTAssertEqual(detail.artifactAvailability, .available)
    XCTAssertEqual(detail.artifacts.count, 1)
    XCTAssertEqual(detail.artifacts.first?.role, "raw")
    XCTAssertEqual(detail.artifacts.first?.byteCount, 128)
    XCTAssertEqual(detail.correlationAvailability, .available)
    XCTAssertEqual(detail.correlation?.jobID, "job-1")
    XCTAssertEqual(detail.correlation?.sessionID, "session-job-1")
    XCTAssertEqual(detail.correlation?.targetID, "target-dayu200-a")
    XCTAssertEqual(detail.correlation?.artifacts.map(\.id), ["artifact-1"])
  }

  func testCorrelationFailsIndependentlyWhenAnOlderStatusHasNoSessionIdentity() throws {
    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-old",
      operationReference: "observe.device@1",
      statusResponse: .success(try currentJobDetailResponse([
        "jobId": "job-old", "operation": "observe.device@1",
        "targetId": "target-dayu200-a", "timeline": ["succeeded"],
      ])),
      evidenceResponse: .failure("not relevant"),
      artifactResponse: .success(try currentArtifactPageResponse([])))

    XCTAssertEqual(detail.timelineAvailability, .available)
    XCTAssertEqual(detail.timeline, ["succeeded"])
    XCTAssertEqual(detail.artifactAvailability, .available)
    guard case .unavailable(let reason) = detail.correlationAvailability else {
      return XCTFail("missing Session identity must not create a correlation")
    }
    XCTAssertTrue(reason.contains("Session identity"))
    XCTAssertNil(detail.correlation)
  }

  func testTraceBeforeAndAfterFactsReachHistoryWithoutClaimingRestore() throws {
    let names = TraceDebugParameterCatalog.definitions.map(\.name)
    let before = names.enumerated().map { index, name -> [String: Any] in
      switch index {
      case 0: return ["name": name, "state": "value", "value": "false"]
      case 1: return ["name": name, "state": "missing"]
      case 2: return ["name": name, "state": "unreadable", "detail": "permission denied"]
      default: return ["name": name, "state": "missing"]
      }
    }
    let after = names.enumerated().map { index, name -> [String: Any] in
      switch index {
      case 0: return ["name": name, "state": "value", "value": "false"]
      case 1: return ["name": name, "state": "value", "value": "true"]
      case 2: return ["name": name, "state": "unreadable", "detail": "permission denied"]
      default: return ["name": name, "state": "missing"]
      }
    }
    let traceProbe: ([[String: Any]]) -> [String: Any] = { parameters in
      [
        "targetId": "TGT-TRACE-1",
        "bindingRevision": 3,
        "supportedTags": ["ace", "app"],
        "parameters": parameters,
      ]
    }
    let evidence = try response([
      "jobId": "job-trace-1",
      "operationReference": "capture.diagnostics@1",
      "catalogDigest": String(repeating: "a", count: 64),
      "bindingRevision": 3,
      "providerId": "hdc",
      "actualEffect": "deviceMutation",
      "executionMode": "execute",
      "terminalState": "succeeded",
      "parameters": ["durationSeconds": 15, "traceCategories": ["ace", "app"]],
      "actualStepKinds": ["captureRemoteFile", "receiveFile"],
      "traceProbeBefore": traceProbe(before),
      "traceProbeAfter": traceProbe(after),
      "blockers": [],
    ])

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-trace-1",
      operationReference: "capture.diagnostics@1",
      evidenceResponse: evidence,
      artifactResponse: .success(try currentArtifactPageResponse([])))

    let parameters = try XCTUnwrap(detail.evidence?.traceParameters)
    XCTAssertEqual(parameters.map(\.name), names)
    XCTAssertEqual(parameters[0].beforeValue, "false")
    XCTAssertEqual(parameters[0].afterValue, "false")
    XCTAssertEqual(parameters[0].comparison, .unchanged)
    XCTAssertEqual(parameters[1].beforeState, "missing")
    XCTAssertEqual(parameters[1].afterValue, "true")
    XCTAssertEqual(parameters[1].comparison, .changed)
    XCTAssertEqual(parameters[2].comparison, .unverified)
    XCTAssertEqual(detail.evidence?.parameters.map(\.name), ["durationSeconds", "traceCategories"])
  }

  func testHistoryRendersTraceDiffBeforeTypedInputsWithExplicitComparisonCopy() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/History/RuntimeHistoryView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/HistoryLocalizable.xcstrings"),
      encoding: .utf8)

    let traceBranch = try XCTUnwrap(view.range(of: "if !evidence.traceParameters.isEmpty"))
    let typedInputs = try XCTUnwrap(view.range(of: "history.parameters.typedInputs"))
    XCTAssertLessThan(traceBranch.lowerBound, typedInputs.lowerBound)
    XCTAssertTrue(view.contains("traceParameterTable(evidence.traceParameters)"))
    XCTAssertTrue(view.contains("Table(parameters)"))
    XCTAssertTrue(view.contains("parameter.comparison"))
    XCTAssertTrue(view.contains("typedParameterGrid(evidence.parameters)"))
    for key in [
      "history.parameters.column.before",
      "history.parameters.column.after",
      "history.parameters.column.status",
      "history.parameters.comparison.unchanged",
      "history.parameters.comparison.changed",
      "history.parameters.comparison.unverified",
    ] {
      XCTAssertTrue(localization.contains("\"\(key)\""), "missing localized key \(key)")
    }
    XCTAssertFalse(
      localization.contains("history.parameters.comparison.restored"),
      "equal readbacks must not be promoted into a restore claim")
  }

  func testEvidenceForAnotherJobOrOperationIsUnavailable() throws {
    let evidence = try response([
      "jobId": "job-other",
      "operationReference": "observe.device@1",
      "catalogDigest": String(repeating: "a", count: 64),
      "providerId": "openharmony-hdc",
      "executionMode": "execute",
      "terminalState": "succeeded",
    ])

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-selected",
      operationReference: "observe.device@1",
      evidenceResponse: evidence,
      artifactResponse: .success(try currentArtifactPageResponse([])))

    guard case .unavailable(let reason) = detail.evidenceAvailability else {
      return XCTFail("mismatched evidence must not become available")
    }
    XCTAssertTrue(reason.contains("did not match"))
    XCTAssertNil(detail.evidence)
  }

  func testOneMalformedArtifactFailsTheSectionWithoutPartialRows() throws {
    let artifacts = RuntimeHistoryTransportResult.success(try currentArtifactPageResponse([
      [
        "artifactId": "artifact-complete",
        "jobId": "job-1",
        "name": "device-facts.json",
        "mediaType": "application/json",
        "byteCount": 128,
        "sha256": String(repeating: "b", count: 64),
        "privacy": "sensitive",
        "status": "published",
        "sourceOperation": "observe.device@1",
        "createdAtUtc": "2026-08-06T07:00:02Z",
        "redactionApplied": true,
      ],
      ["artifactId": "artifact-incomplete", "jobId": "job-1"],
    ]))

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-1",
      operationReference: "observe.device@1",
      evidenceResponse: .failure("not relevant"),
      artifactResponse: artifacts)

    guard case .unavailable(let reason) = detail.artifactAvailability else {
      return XCTFail("incomplete metadata must fail the complete Artifact section")
    }
    XCTAssertTrue(reason.contains("incomplete"))
    XCTAssertTrue(detail.artifacts.isEmpty, "no partial Artifact row may survive")
  }

  // The App-facing surface has only bounded reads. If a mutating method is
  // ever added here it stops being a surface the sandboxed GUI may hold, so
  // the absence is pinned rather than assumed.
  func testTheApplicationSurfaceExposesNoMutation() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(
          path: "Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift"),
      encoding: .utf8)

    let protocolBody = try XCTUnwrap(
      source.range(of: "public protocol RuntimeHistoryApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 2,
      "the App-facing Runtime surface must expose only paged summary reads")
    XCTAssertTrue(protocolBody.contains("func refreshHistory()"))
    XCTAssertTrue(protocolBody.contains("func loadOlderHistory()"))

    let detailProtocolBody = try XCTUnwrap(
      source.range(of: "public protocol RuntimeJobDetailApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      detailProtocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 3,
      "the detail surface exposes only detail, bounded local preview and bounded export")
    XCTAssertTrue(detailProtocolBody.contains("func loadJobDetail("))
    XCTAssertTrue(detailProtocolBody.contains("func exportArtifact("))
    XCTAssertTrue(detailProtocolBody.contains("func readArtifact("))
    XCTAssertTrue(detailProtocolBody.contains("maximumBytes: Int"))
    XCTAssertTrue(detailProtocolBody.contains("allowSensitive: Bool"))

    // Only the read-only method may be named anywhere in this file: a
    // mutating method name appearing here would mean the App can compose a
    // frame the daemon's allowlist is the only thing refusing.
    for mutating in [
      "job.submit", "job.run", "job.cancel", "job.reconcile", "job.plan",
      "target.adopt", "artifact.import", "artifact.export",
    ] {
      XCTAssertFalse(
        source.contains("\"\(mutating)"),
        "the App-facing facade must not be able to name \(mutating)")
    }
    XCTAssertTrue(source.contains("method: \"job.list\""))
    XCTAssertTrue(source.contains("\"order\": .string(\"createdAtDescJobIdAsc\")"))
    XCTAssertTrue(source.contains("\"includeTimeline\": .bool(false)"))
    XCTAssertTrue(source.contains("\"includeCurrent\": .bool(true)"))
    XCTAssertTrue(source.contains("RuntimeAppReadResources.jobDetail("))
    XCTAssertTrue(source.contains("request(\"job.evidence\""))
    XCTAssertTrue(source.contains("RuntimeAppReadResources.artifactInventory("))
    XCTAssertTrue(source.contains("method: \"artifact.read\""))
  }

  func testEveryAppWorkspaceUsesTheBoundedRecentSummaryPolicy() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let workflow = repository.appending(
      path: "Packages/ArkDeckKit/Sources/ArkDeckWorkflows")
    for file in [
      "DebugApplicationFacade.swift", "TraceApplicationFacade.swift",
      "UIDumpApplicationFacade.swift",
    ] {
      let source = try String(
        contentsOf: workflow.appending(path: file), encoding: .utf8)
      XCTAssertTrue(
        source.contains("params: RuntimeAppReadResources.recentSummaryParams"),
        "\(file) must not restore an unbounded startup history read")
    }
    let deviceList = try String(
      contentsOf: workflow.appending(path: "DeviceListApplicationFacade.swift"),
      encoding: .utf8)
    XCTAssertFalse(
      deviceList.contains("method: \"job.list"),
      "device startup must use the daemon's compact projection, not read job history")
    let engine = try String(
      contentsOf: workflow.appending(path: "RuntimeJobEngine.swift"), encoding: .utf8)
    XCTAssertTrue(engine.contains("public func latestSucceededDeviceObservations("))
    XCTAssertTrue(engine.contains("pageSize: Int = 250"))
    let policy = try String(
      contentsOf: workflow.appending(path: "XPCConnectionBox.swift"),
      encoding: .utf8)
    XCTAssertTrue(policy.contains("\"pageSize\": .integer(250)"))
    XCTAssertTrue(policy.contains("\"order\": .string(\"createdAtDescJobIdAsc\")"))
    XCTAssertTrue(policy.contains("\"includeTimeline\": .bool(false)"))
  }

  func testHistoryLoadsFullTimelineOnlyWithSelectedDetail() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/History/RuntimeHistoryView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/HistoryLocalizable.xcstrings"),
      encoding: .utf8)

    XCTAssertTrue(view.contains("detail.timelineAvailability"))
    XCTAssertTrue(view.contains("timelineEntries(detail.timeline, job: job)"))
    XCTAssertTrue(view.contains("presentation.hasOlderJobs"))
    XCTAssertTrue(view.contains("history.loadOlder"))
    XCTAssertTrue(view.contains("job.activityDate"))
    XCTAssertTrue(localization.contains("\"history.action.loadOlder\""))
  }

  func testHistoryActivityCenterClosesFilterCacheAndContextRegressions() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/History/RuntimeHistoryView.swift"),
      encoding: .utf8)
    let app = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/HistoryLocalizable.xcstrings"),
      encoding: .utf8)

    for identifier in [
      "history.filter.activity", "history.filter.status", "history.filter.mode",
      "history.filter.session",
      "history.filter.device", "history.filter.time",
    ] {
      XCTAssertTrue(view.contains(".accessibilityIdentifier(\"\(identifier)\")"))
    }
    XCTAssertEqual(
      view.components(separatedBy: ".accessibilityIdentifier(\"history.filter.search\")").count
        - 1,
      1,
      "wide and compact layouts must share one search field rather than duplicate state")
    XCTAssertTrue(view.contains("filterSidebar"))
    XCTAssertTrue(view.contains("compactFilters"))
    XCTAssertTrue(view.contains("filterPickers"))
    XCTAssertTrue(view.contains(".contentShape(.rect)"))

    XCTAssertFalse(
      view.contains("@AppStorage"),
      "History saved filters must be owned by Runtime rather than the App container")
    XCTAssertTrue(view.contains("RuntimeHistoryFilterQuery("))
    XCTAssertTrue(view.contains("onSaveFilter?(currentFilterQuery)"))
    XCTAssertTrue(view.contains("history.filter.reloadSaved"))
    XCTAssertTrue(view.contains("expectedGeneration: resource.generation"))
    XCTAssertGreaterThanOrEqual(
      view.components(separatedBy: "self.savedFilterRequestID == requestID").count - 1,
      4,
      "loads, migration reconciliation and mutations must all reject superseded replies")
    XCTAssertTrue(
      view.contains("savedActivity == \"toolkit\" ? \"device\""),
      "saved filters from before the rename must migrate to Device")
    XCTAssertTrue(
      view.contains("HistoryActivityFilter(rawValue: savedFilterQuery.activity) ?? .all"),
      "Runtime filters must restore normally and unknown values must fail to all")

    XCTAssertTrue(view.contains("detailGeneration &+= 1"))
    XCTAssertTrue(view.contains("self.detailsByJobID = [:]"))
    XCTAssertTrue(view.contains("func reloadDetail(jobID:"))
    XCTAssertTrue(
      view.contains(".onChange(of: isRefreshInFlight)"),
      "refresh must restart an invalidated detail even when the cache was already empty")
    XCTAssertTrue(view.contains("self.detailGeneration == generation"))
    XCTAssertTrue(view.contains("self.detailRequestIDs[jobID] == requestID"))
    let requestCheck = try XCTUnwrap(view.range(of: "self.detailRequestIDs[jobID] == requestID"))
    let loadingRemoval = try XCTUnwrap(view.range(of: "self.loadingDetailJobIDs.remove(jobID)"))
    XCTAssertLessThan(
      requestCheck.lowerBound, loadingRemoval.lowerBound,
      "a superseded read must not clear the newer request's loading state")
    XCTAssertTrue(view.contains("case .loading:"))
    XCTAssertTrue(view.contains("history.loading"))

    let refresh = try XCTUnwrap(view.range(of: "  func refresh() {"))
    let loadOlder = try XCTUnwrap(view.range(of: "  func loadOlder() {"))
    let loadDetail = try XCTUnwrap(view.range(of: "  func loadDetail(jobID:"))
    let refreshBody = String(view[refresh.lowerBound..<loadOlder.lowerBound])
    let olderBody = String(view[loadOlder.lowerBound..<loadDetail.lowerBound])
    XCTAssertTrue(refreshBody.contains("historyGeneration &+= 1"))
    XCTAssertTrue(refreshBody.contains("isLoadOlderInFlight = false"))
    let generationGuard = try XCTUnwrap(
      olderBody.range(of: "self.historyGeneration == generation"))
    let spinnerReset = try XCTUnwrap(
      olderBody.range(of: "defer { self.isLoadOlderInFlight = false }"))
    let assignment = try XCTUnwrap(olderBody.range(of: "self.presentation = next"))
    XCTAssertLessThan(generationGuard.lowerBound, spinnerReset.lowerBound)
    XCTAssertLessThan(generationGuard.lowerBound, assignment.lowerBound)

    XCTAssertTrue(app.contains("RuntimeHistoryWorkspaceContext"))
    XCTAssertTrue(app.contains("HistoryWorkspaceContextBanner"))
    XCTAssertTrue(app.contains("openHistoryWorkspace"))
    XCTAssertTrue(app.contains("openHistoryContext(context)"))
    XCTAssertTrue(app.contains("historyContext: visibleHistoryContext"))
    XCTAssertFalse(
      app.contains("HistoryWorkspaceDestination"),
      "History must pass exact record context rather than a destination-only navigation token")

    for key in [
      "history.activity.device", "history.activity.other",
      "history.activity.open.detailUnavailable", "history.activity.open.unsupported",
      "history.context.title", "history.context.readOnly", "history.detail.reload",
      "history.loading",
    ] {
      XCTAssertTrue(localization.contains("\"\(key)\""), "missing localized key \(key)")
    }
  }

  func testHistoricalWorkspaceReadsRejectSupersededPresentationResults() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let viewer = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift"),
      encoding: .utf8)
    let device = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Device/DeviceWorkspaceViewModel.swift"),
      encoding: .utf8)
    let trace = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Trace/TraceWorkspaceView.swift"),
      encoding: .utf8)
    XCTAssertTrue(viewer.contains("self.captureGeneration == generation"))
    XCTAssertTrue(viewer.contains("captureGeneration &+= 1"))
    XCTAssertTrue(viewer.contains("viewer.history.loading"))
    XCTAssertTrue(device.contains("self.screenGeneration == generation"))
    XCTAssertTrue(device.contains("adopted.filter { $0.adoptedTargetID == targetID }"))
    XCTAssertTrue(device.contains("liveness = DeviceFrameLiveness()"))
    XCTAssertTrue(trace.contains("viewerReadGeneration == generation"))
    XCTAssertTrue(trace.contains("self.viewerReadGeneration == viewerGenerationAtSubmission"))
  }

  func testDebugArtifactRowsUseTheReviewedBoundedExporterInsteadOfAPlaceholderButton() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Debug/DebugWorkspaceView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/DebugLocalizable.xcstrings"),
      encoding: .utf8)

    XCTAssertTrue(view.contains("runtimeArtifactRows("))
    XCTAssertTrue(view.contains("model.exportArtifact("))
    XCTAssertTrue(view.contains(".confirmationDialog("))
    XCTAssertTrue(view.contains("allowSensitive: row.artifact.privacy == \"sensitive\""))
    XCTAssertTrue(view.contains("exportStatesByArtifactID"))
    XCTAssertFalse(
      view.contains("Button(DebugL10n.text(\"debug.logs.export\")) {}"),
      "Debug must not regress to a permanently disabled export placeholder")
    XCTAssertFalse(
      localization.contains("debug.blocked.artifactExport"),
      "copy must not claim the reviewed artifact.read channel is unavailable")
  }
}

actor HistoryRPCScenario {
  private var answers: [(String, RuntimeHistoryTransportResult)]
  private var calls: [(String, [String: JSONValue])] = []

  init(_ answers: [(String, RuntimeHistoryTransportResult)]) { self.answers = answers }

  func request(_ method: String, _ parameters: [String: JSONValue]) -> RuntimeHistoryTransportResult {
    calls.append((method, parameters))
    guard !answers.isEmpty, answers[0].0 == method else { return .failure("unexpected fixture RPC") }
    return answers.removeFirst().1
  }

  func recordedCalls() -> [(String, [String: JSONValue])] { calls }
}
