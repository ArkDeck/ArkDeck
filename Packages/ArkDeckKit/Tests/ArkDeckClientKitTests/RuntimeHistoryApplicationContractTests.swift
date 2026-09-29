@testable import ArkDeckClientKit
// What the App is allowed to conclude from a daemon answer.
//
// The dangerous failure for a read-only history surface is not a crash, it is
// a confident wrong reading: showing an empty, calm history when the truth is
// "could not read it", or folding an unknown outcome into a terminal state.
// These pin against exactly that.

import Foundation
import Testing

@testable import ArkDeckCore

struct RuntimeHistoryApplicationContractTests {
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

  @Test func boundedPreviewReadsExactChunksAndVerifiesTheCompleteHash() async throws {
    let bytes = Data(repeating: 65, count: 300_000)
    let boundary = 256 * 1_024
    let transport = HistoryRPCScenario([
      ("artifact.read", try chunk(bytes.prefix(boundary), total: bytes.count, offset: 0, eof: false, digest: SHA256Hex.string(of: bytes))),
      ("artifact.read", try chunk(bytes.suffix(bytes.count - boundary), total: bytes.count, offset: boundary, eof: true, digest: SHA256Hex.string(of: bytes))),
    ])
    let reader = RuntimeJobDetailXPCProvider(request: { await transport.request($0, $1) })
    let result = await reader.readArtifact(
      jobID: "job-preview", artifact: previewArtifact(bytes), maximumBytes: 400_000, allowSensitive: false)
    #expect(result == .loaded(bytes))
    let calls = await transport.recordedCalls()
    #expect(calls.map(\.0) == ["artifact.read", "artifact.read"])
    #expect(calls.map { $0.1["offset"] } == [.integer(0), .integer(Int64(boundary))])
    #expect(calls.allSatisfy {
      $0.1["owner"] == .object(["kind": .string("job"), "id": .string("job-preview")]) && $0.1["artifactId"] == .string("artifact-preview")
        && $0.1["maxBytes"] == .integer(Int64(boundary)) && $0.1["allowSensitive"] == .bool(false)
    })
  }

  @Test func previewPrivacyPublicationAndSizeRefusalsReadNoBytes() async {
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
      else { Issue.record("preview bypassed its privacy or byte bound"); return }
    }
    let calls = await transport.recordedCalls()
    #expect(calls.isEmpty)
  }

  @Test func previewRejectsWrongOffsetEarlyEOFAndWrongHash() async throws {
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
      else { Issue.record("drifting bytes were presented as verified"); return }
      let calls = await transport.recordedCalls()
      #expect(calls.count == 1)
    }
  }

  private func cancellableJob(state: String = "running", unknown: Bool = false) -> RuntimeJobSummaryPresentation {
    RuntimeJobSummaryPresentation(
      id: "job-cancel", operationReference: "capture.diagnostics@1", targetID: "target-cancel",
      state: state, waitingForHuman: false, outcomeUnknown: unknown, outstandingResidueCount: 0,
      timeline: [], sessionID: "session-cancel", actualEffect: "readOnly")
  }

  @Test func globalCancellationUsesFreshIdentityAndOnlyRequestsTheSafeBoundary() async throws {
    let transport = HistoryRPCScenario([
      ("job.show", .success(try currentJobDetailResponse([
        "jobId": "job-cancel", "operation": "capture.diagnostics@1", "targetId": "target-cancel",
        "sessionId": "session-cancel", "state": "running", "outcomeUnknown": false,
      ]))),
      ("job.cancel", try response(["cancelRequested": true])),
    ])
    let control = RuntimeJobControlXPCProvider(request: { await transport.request($0, $1) })
    let result = await control.cancel(cancellableJob())
    #expect(result == .requested, "acceptance must not be projected as terminal cancelled")
    let calls = await transport.recordedCalls()
    #expect(calls.map(\.0) == ["job.show", "job.cancel"])
    #expect(calls.allSatisfy { $0.1 == ["jobId": .string("job-cancel")] })
  }

  @Test func globalCancellationRefusesTerminalUnknownAndDriftingJobsWithoutCancelDispatch() async throws {
    let noRead = HistoryRPCScenario([])
    let closed = RuntimeJobControlXPCProvider(request: { await noRead.request($0, $1) })
    for job in [cancellableJob(state: "succeeded"), cancellableJob(unknown: true), cancellableJob(state: "unrecognized")] {
      guard case .refused = await closed.cancel(job) else { Issue.record("non-cancellable Job was accepted"); return }
    }
    let initialCalls = await noRead.recordedCalls()
    #expect(initialCalls.isEmpty)

    for drift: [String: Any] in [
      ["jobId": "another-job"], ["operation": "flash.dayu200@1"], ["targetId": "another-target"],
      ["sessionId": "another-session"], ["state": "succeeded"], ["outcomeUnknown": true],
    ] {
      var status: [String: Any] = [
        "jobId": "job-cancel", "operation": "capture.diagnostics@1", "targetId": "target-cancel",
        "sessionId": "session-cancel", "state": "running", "outcomeUnknown": false,
      ]
      status.merge(drift) { _, new in new }
      let transport = HistoryRPCScenario([("job.show", .success(try currentJobDetailResponse(status)))])
      let control = RuntimeJobControlXPCProvider(request: { await transport.request($0, $1) })
      guard case .refused = await control.cancel(cancellableJob()) else { Issue.record("fresh drift was accepted"); return }
      let calls = await transport.recordedCalls()
      #expect(calls.map(\.0) == ["job.show"])
    }
  }

  @Test func cancellationDisconnectDuringFreshReadDoesNotDispatch() async {
    let transport = HistoryRPCScenario([("job.show", .failure("connection interrupted"))])
    let control = RuntimeJobControlXPCProvider(request: { await transport.request($0, $1) })
    guard case .refused = await control.cancel(cancellableJob()) else {
      Issue.record("cancellation requires current Job identity")
      return
    }
    let calls = await transport.recordedCalls()
    #expect(calls.map(\.0) == ["job.show"])
  }

  // A complete answer is the only thing that produces an available history.
  @Test func aCompleteJobListBecomesAvailableHistory() {
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

    #expect(presentation.availability == .available)
    #expect(presentation.jobs.count == 1)
    let job = presentation.jobs.first
    #expect(job != nil)
    #expect(job?.id == "job-1")
    #expect(job?.operationReference == "observe.devices@1")
    #expect(job?.targetID == "t-1")
    #expect(job?.state == "succeeded")
    #expect(job?.timeline == ["queued", "running", "succeeded"])
    #expect(job?.needsAttention == false)
    #expect(job?.executionMode == "execute")
    #expect(job?.sessionID == "session-job-1")
    #expect(job?.actualEffect == "readOnly")
    #expect(job?.createdAtUTC == "2026-08-06T07:00:00Z")
    #expect(job?.startedAtUTC == "2026-08-06T07:00:01Z")
    #expect(job?.finishedAtUTC == "2026-08-06T07:00:02Z")
    #expect(job?.requiresRecoveryGuidance == false)
  }

  @Test func optionalHistoryFactsAreNotInventedWhenAbsent() throws {
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

    let job = try #require(presentation.jobs.first)
    #expect(job.executionMode == nil)
    #expect(job.sessionID == nil)
    #expect(job.actualEffect == nil)
    #expect(job.createdAtUTC == nil)
    #expect(job.startedAtUTC == nil)
    #expect(job.finishedAtUTC == nil)
  }

  @Test func workspaceKindProjectionDistinguishesSharedDiagnosticsRequests() {
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: [
          "uiDump": .bool(true),
          "uiScreenshot": .bool(true),
          "uiComponentTree": .bool(true),
        ])
        == .viewer)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: ["traceCategories": .array([.string("ace")])])
        == .trace)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: [
          "uiScreenshot": .bool(true),
          "captureHilog": .bool(false),
          "crashLogs": .bool(false),
        ])
        == .device)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        inputs: [
          "uiScreenshot": .bool(true),
          "captureHilog": .bool(true),
        ],
        clientName: ArkDeckAgentClientName.debugLogsWorkspace)
        == .debug,
      "a diagnostic capture with HiLog must not become Device merely because it has a screenshot")
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1", inputs: [:])
        == .diagnostics)
  }

  @Test func deviceWorkspaceReadsThePublishedHistoryNameAfterRename() throws {
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
    #expect(presentation.availability == .available)
    #expect(presentation.jobs.first?.workspaceKind == .device)
    #expect(
      String(decoding: try JSONEncoder().encode(RuntimeWorkspaceKind.device), as: UTF8.self)
        == "\"toolkit\"",
      "the rename must remain readable by an existing daemon or App")
  }

  @Test func workspaceKindProjectionMapsOnlyKnownProductSurfaces() {
    let cases: [(String, RuntimeWorkspaceKind)] = [
      ("flash.dayu200@1", .flash),
      ("observe.device@1", .viewer),
      ("analyzer.analyze-trace@1", .trace),
      ("analyzer.summarize-hilog@1", .diagnostics),
      ("debug.hap@1", .debug),
      ("input.tap@1", .device),
    ]
    for (operation, expected) in cases {
      #expect(
        RuntimeWorkspaceKindProjection.kind(forOperation: operation, inputs: [:])
          == expected,
        "\(operation)")
    }
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "future.unknown@1", inputs: [:]) == nil)
    #expect(
      RuntimeWorkspaceKindProjection.unambiguousKind(
        forOperation: "capture.diagnostics@1") == nil,
      "an older daemon did not publish enough facts to guess a shared diagnostics origin")
  }

  @Test func workspaceKindAndUnambiguousOperationProjectCurrentSummaries() throws {
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

    #expect(presentation.jobs[0].workspaceKind == .viewer)
    #expect(presentation.jobs[0].resolvedWorkspaceKind == .viewer)
    #expect(presentation.jobs[1].workspaceKind == nil)
    #expect(presentation.jobs[1].resolvedWorkspaceKind == .debug)
    #expect(presentation.jobs[2].resolvedWorkspaceKind == nil)
  }

  @Test func legacyDetailParametersOnlyResolveUnambiguousSharedCaptures() {
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [.init(name: "uiComponentTree", value: "true")])
        == .viewer)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [.init(name: "traceCategories", value: "[\"ace\"]")])
        == .trace)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [
          .init(name: "uiScreenshot", value: "true"),
          .init(name: "captureHilog", value: "false"),
          .init(name: "traceCategories", value: "[]"),
        ])
        == .device)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1", parameters: []) == nil)
    #expect(
      RuntimeWorkspaceKindProjection.kind(
        forOperation: "capture.diagnostics@1",
        parameters: [.init(name: "captureHilog", value: "true")]) == nil,
      "the old evidence has no client provenance to separate Diagnostics and Debug")
  }

  @Test func historyWorkspaceContextCarriesExactReadOnlyRecordAndRefusesMismatches() throws {
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

    let context = try #require(RuntimeHistoryWorkspaceContext(job: job, detail: detail))
    #expect(context.jobID == job.id)
    #expect(context.operationReference == job.operationReference)
    #expect(context.targetID == "TGT-1")
    #expect(context.bindingRevision == 7)
    #expect(context.executionMode == "execute")
    #expect(context.sessionID == "session-viewer")
    #expect(context.threadID == "thread-viewer")
    #expect(context.parameters.map(\.name) == ["uiComponentTree"])

    let anotherJob = RuntimeJobSummaryPresentation(
      id: "job-other", operationReference: job.operationReference,
      targetID: job.targetID, state: job.state, waitingForHuman: false,
      outcomeUnknown: false, outstandingResidueCount: 0, timeline: [],
      workspaceKind: .viewer)
    #expect(RuntimeHistoryWorkspaceContext(job: anotherJob, detail: detail) == nil)

    let legacyShared = RuntimeJobSummaryPresentation(
      id: job.id, operationReference: job.operationReference,
      targetID: job.targetID, state: job.state, waitingForHuman: false,
      outcomeUnknown: false, outstandingResidueCount: 0, timeline: [])
    let legacyContext = try #require(
      RuntimeHistoryWorkspaceContext(job: legacyShared, detail: detail))
    #expect(legacyContext.workspaceKind == .viewer)

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
    #expect(
      RuntimeHistoryWorkspaceContext(job: legacyShared, detail: ambiguousDetail) == nil,
      "legacy diagnostics and Debug requests remain unknown without client provenance")
  }

  @Test func pagedSummaryPreservesRuntimeCurrentRowsWithoutInventingACompactTimeline() throws {
    let cursor = "11111111-1111-4111-8111-111111111111.41"
    let data = try currentJobPageResponse([
      ["jobId": "job-old-current", "operation": "flash.dayu200@1", "targetId": "TGT-1",
       "state": "waitingForRecovery", "current": true, "outcomeUnknown": true, "timeline": NSNull()],
      ["jobId": "job-newest", "operation": "observe.device@1", "targetId": "TGT-1",
       "state": "succeeded", "current": false, "timeline": NSNull()],
    ], cursor: cursor)
    switch RuntimeHistoryResponseDecoding.page(from: data) {
    case .unavailable(let reason): Issue.record("complete page must decode: \(reason)")
    case .available(let jobs, let nextCursor):
      #expect(jobs.map(\.id) == ["job-old-current", "job-newest"])
      #expect(jobs.map(\.timeline) == [[], []])
      #expect(jobs[0].requiresRecoveryGuidance)
      #expect(nextCursor == cursor)
    }
  }

  // The load-bearing distinction: a daemon that answered "no jobs" and a
  // daemon that could not be read must never produce the same presentation.
  @Test func anEmptyHistoryIsNotTheSameAsAnUnreadableOne() {
    let empty = RuntimeHistoryResponseDecoding.presentation(from: try! currentJobPageResponse([]))
    #expect(empty.availability == .available)
    #expect(empty.jobs.isEmpty)

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
      #expect(
        presentation.availability != .available,
        "an unreadable answer must never present as available history: \(unreadable)")
      #expect(
        presentation.jobs.isEmpty,
        "an unavailable history must carry no jobs: \(unreadable)")
    }
  }

  // A daemon error is surfaced with its own code and message rather than
  // flattened into a generic failure the user cannot act on.
  @Test func aDaemonErrorKeepsItsCodeAndMessage() {
    let presentation = decode(
      #"{"ok":false,"id":"x","error":{"code":"malformedFrame","message":"undecodable request frame"}}"#
    )
    let reason = reason(presentation)
    #expect(reason != nil)
    #expect(
      reason?.contains("malformedFrame") == true, "the code must survive: \(reason ?? "")")
    #expect(
      reason?.contains("undecodable request frame") == true,
      "the daemon's own message must survive: \(reason ?? "")")
  }

  // A job missing an identifying fact fails the whole read rather than being
  // silently dropped: a history that quietly omits rows is worse than one
  // that says it could not be read.
  @Test func aJobMissingAnIdentifyingFactFailsTheWholeRead() {
    for missing in ["jobId", "operation", "targetId", "state"] {
      var entry: [String: Any] = [
        "jobId": "job-1", "operation": "observe.devices@1", "targetId": "t-1",
        "state": "succeeded",
      ]
      entry.removeValue(forKey: missing)
      let data = try? JSONSerialization.data(
        withJSONObject: ["ok": true, "id": "x", "result": [entry]])
      let presentation = RuntimeHistoryResponseDecoding.presentation(from: data ?? Data())

      #expect(
        presentation.availability != .available,
        "a job without \(missing) must not yield an available history")
      #expect(presentation.jobs.isEmpty, "no partial row may survive a missing \(missing)")
    }
  }

  // An unknown outcome and a waiting job are never presentable as settled.
  @Test func unknownOutcomeAndHumanWaitBothRaiseNeedsAttention() {
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

    #expect(presentation.availability == .available)
    #expect(presentation.jobs.map(\.needsAttention) == [true, true, false])
    #expect(presentation.jobs.map(\.requiresRecoveryGuidance) == [true, true, false])
    #expect(presentation.jobs.first?.outstandingResidueCount == 2)
  }

  @Test func recoveryStatesRaiseGuidanceUntilRuntimeEstablishesTheCurrentEpoch() {
    for state in [
      "waitingForRecovery", "awaitingRebindConfirmation",
      "resumeAtConfirmedSafeBoundary", "userAbandonRequested",
    ] {
      let job = RuntimeJobSummaryPresentation(
        id: "job-\(state)", operationReference: "flash.dayu200", targetID: "t-1",
        state: state, waitingForHuman: false, outcomeUnknown: false,
        outstandingResidueCount: 0, timeline: [])
      #expect(job.requiresRecoveryGuidance, "\(state)")
    }

    let running = RuntimeJobSummaryPresentation(
      id: "job-running", operationReference: "flash.dayu200", targetID: "t-1",
      state: "running", waitingForHuman: false, outcomeUnknown: false,
      outstandingResidueCount: 0, timeline: [])
    #expect(!running.requiresRecoveryGuidance)
    #expect(running.isCurrentActivity)

    let resolvedRecovery = RuntimeJobSummaryPresentation(
      id: "job-resolved-recovery", operationReference: "flash.dayu200", targetID: "t-1",
      state: "waitingForRecovery", waitingForHuman: false, outcomeUnknown: true,
      outstandingResidueCount: 0, timeline: ["running", "waitingForRecovery"],
      supersededByRecoveryEpochID: "recovery-epoch-current")
    #expect(resolvedRecovery.hasEstablishedCurrentEpoch)
    #expect(!resolvedRecovery.requiresRecoveryGuidance)
    #expect(
      !resolvedRecovery.isCurrentActivity,
      "historical unknown states remain nonterminal for audit but are not current activity")
  }

  @Test func targetAliasResolutionKeepsUnknownOutcomeButSettlesCurrentEpochAttention() throws {
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

    let job = try #require(presentation.jobs.first)
    #expect(job.outcomeUnknown, "the historical outcome is never rewritten")
    #expect(
      job.resolvedByTargetAliasResolutionID
        == "target-alias-resolution-0123456789abcdef")
    #expect(job.hasEstablishedCurrentEpoch)
    #expect(
      !job.needsAttention,
      "a later complete Flash established the current epoch without settling the old outcome")
    #expect(
      !job.requiresRecoveryGuidance,
      "resolved History stays inspectable without remaining a global operator action")
  }

  @Test func flashActivityUsesRecencyAfterResolvedUnknownsWithoutRewritingHistory() throws {
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
    #expect(presentation.focusedFlashActivity?.id == "latest-flash")
    #expect(
      presentation.flashActivityJobs.map(\.id) == ["latest-flash", "old-superseded", "old-alias"])
    #expect(presentation.jobs == originalJobs, "the paged Runtime history remains untouched")
    #expect(presentation.jobs[0].outcomeUnknown)
    #expect(presentation.jobs[1].outcomeUnknown)
    #expect(presentation.jobs[0].state == "waitingForRecovery")
    #expect(presentation.jobs[1].state == "waitingForRecovery")
  }

  @Test func flashActivityUnresolvedStopsOutrankNewerSuccessAndRunningJobs() {
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
      #expect(
        RuntimeHistoryPresentation(availability: .available, jobs: jobs).focusedFlashActivity?.id
          == expected)
    }
  }

  @Test func flashActivityMissingDatesAndEqualDatesHaveStableOrder() {
    let jobs = ["b", "a"].map { id in
      RuntimeJobSummaryPresentation(
        id: id, operationReference: "flash.dayu200", targetID: "t-1", state: "planned",
        waitingForHuman: false, outcomeUnknown: false, outstandingResidueCount: 0, timeline: [])
    }
    let missing = RuntimeHistoryPresentation(availability: .available, jobs: jobs)
    #expect(missing.flashActivityJobs.map(\.id) == ["a", "b"])
    #expect(missing.flashActivityJobs.allSatisfy { $0.activityDate == nil })
    let dated = jobs.map { job in
      RuntimeJobSummaryPresentation(
        id: job.id, operationReference: job.operationReference, targetID: job.targetID,
        state: job.state, waitingForHuman: false, outcomeUnknown: false,
        outstandingResidueCount: 0, timeline: [], createdAtUTC: "2026-08-06T08:00:00Z")
    }
    #expect(
      RuntimeHistoryPresentation(availability: .available, jobs: dated).flashActivityJobs.map(\.id)
        == ["a", "b"])
    #expect(RuntimeHistoryPresentation(availability: .available, jobs: []).focusedFlashActivity == nil)
  }

  @Test func completeEvidenceAndArtifactMetadataBecomeReadOnlyDetail() throws {
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

    #expect(detail.timelineAvailability == .available)
    #expect(detail.timeline == ["queued", "running", "succeeded"])
    #expect(detail.evidenceAvailability == .available)
    #expect(detail.evidence?.providerID == "openharmony-hdc")
    #expect(detail.evidence?.parameters.map(\.name) == ["includeToolFacts", "limit"])
    #expect(detail.evidence?.parameters.map(\.value) == ["true", "2"])
    #expect(detail.evidence?.parametersWereReported == true)
    #expect(detail.evidence?.typedParameters == ["includeToolFacts": .bool(true), "limit": .integer(2)])
    #expect(detail.evidence?.observedBindingRevision == 8)
    #expect(detail.artifactAvailability == .available)
    #expect(detail.artifacts.count == 1)
    #expect(detail.artifacts.first?.role == "raw")
    #expect(detail.artifacts.first?.byteCount == 128)
    #expect(detail.correlationAvailability == .available)
    #expect(detail.correlation?.jobID == "job-1")
    #expect(detail.correlation?.sessionID == "session-job-1")
    #expect(detail.correlation?.targetID == "target-dayu200-a")
    #expect(detail.correlation?.artifacts.map(\.id) == ["artifact-1"])
  }

  /// Two separate things used to be reported as one: an envelope for a
  /// different Job, and an envelope for the right Job that is missing a fact
  /// the Runtime must publish. Both said "did not match the selected Job",
  /// which sent an operator looking for an identity problem that was not
  /// there — measured on the 2026-09-07 GJ-4 window, where the missing fact
  /// was the whole story.
  @Test func missingPublishedFactsAreNotReportedAsAJobIdentityMismatch() throws {
    func detail(_ evidence: [String: Any]) throws -> RuntimeJobDetailPresentation {
      RuntimeJobDetailResponseDecoding.presentation(
        jobID: "job-1", operationReference: "flash.full-restore@1",
        statusResponse: .success(try currentJobDetailResponse([
          "jobId": "job-1", "operation": "flash.full-restore@1",
          "targetId": "target-dayu200-a", "sessionId": "session-job-1",
          "timeline": ["queued", "running", "waitingForRecovery"],
        ])),
        evidenceResponse: try response(evidence),
        artifactResponse: .success(try currentArtifactPageResponse([])))
    }
    var complete: [String: Any] = [
      "jobId": "job-1",
      "operationReference": "flash.full-restore@1",
      "catalogDigest": String(repeating: "a", count: 64),
      "providerId": "arkforge",
      "executionMode": "execute",
      "terminalState": "outcomeUnknown",
      "actualStepKinds": NSNull(),
      "blockers": ["outcomeUnknown"],
    ]

    // The Runtime could not prove the steps. That is a readable answer, and
    // an empty list is not the same claim as "unknown".
    let unknownSteps = try detail(complete)
    #expect(unknownSteps.evidenceAvailability == .available)
    #expect(unknownSteps.evidence?.actualStepKinds == [])
    #expect(unknownSteps.evidence?.actualStepKindsWereReported == false)
    #expect(unknownSteps.evidence?.providerID == "arkforge")

    complete["actualStepKinds"] = ["flashPartition"]
    let reportedSteps = try detail(complete)
    #expect(reportedSteps.evidence?.actualStepKinds == ["flashPartition"])
    #expect(reportedSteps.evidence?.actualStepKindsWereReported == true)

    var missingProvider = complete
    missingProvider["providerId"] = NSNull()
    guard case .unavailable(let missingReason) = try detail(missingProvider).evidenceAvailability
    else { Issue.record("an unpublishable fact must not read as available evidence"); return }
    #expect(missingReason.contains("missing facts"), "\(missingReason)")
    #expect(!missingReason.contains("did not match"), "\(missingReason)")

    // Negative control: a genuine identity mismatch still says so.
    var foreign = complete
    foreign["jobId"] = "job-somebody-else"
    guard case .unavailable(let foreignReason) = try detail(foreign).evidenceAvailability
    else { Issue.record("evidence for another Job must not be shown for this one"); return }
    #expect(foreignReason.contains("did not match"), "\(foreignReason)")
  }

  @Test func correlationFailsIndependentlyWhenAnOlderStatusHasNoSessionIdentity() throws {
    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-old",
      operationReference: "observe.device@1",
      statusResponse: .success(try currentJobDetailResponse([
        "jobId": "job-old", "operation": "observe.device@1",
        "targetId": "target-dayu200-a", "timeline": ["succeeded"],
      ])),
      evidenceResponse: .failure("not relevant"),
      artifactResponse: .success(try currentArtifactPageResponse([])))

    #expect(detail.timelineAvailability == .available)
    #expect(detail.timeline == ["succeeded"])
    #expect(detail.artifactAvailability == .available)
    guard case .unavailable(let reason) = detail.correlationAvailability else {
      Issue.record("missing Session identity must not create a correlation")
      return
    }
    #expect(reason.contains("Session identity"))
    #expect(detail.correlation == nil)
  }

  @Test func traceBeforeAndAfterFactsReachHistoryWithoutClaimingRestore() throws {
    let names = RuntimeTraceParameterName.allCases.map(\.rawValue)
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

    let parameters = try #require(detail.evidence?.traceParameters)
    #expect(parameters.map(\.name) == names)
    #expect(parameters[0].beforeValue == "false")
    #expect(parameters[0].afterValue == "false")
    #expect(parameters[0].comparison == .unchanged)
    #expect(parameters[1].beforeState == "missing")
    #expect(parameters[1].afterValue == "true")
    #expect(parameters[1].comparison == .changed)
    #expect(parameters[2].comparison == .unverified)
    #expect(detail.evidence?.parameters.map(\.name) == ["durationSeconds", "traceCategories"])
  }

  @Test func historyRendersTraceDiffBeforeTypedInputsWithExplicitComparisonCopy() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/History/RuntimeHistoryView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/HistoryLocalizable.xcstrings"),
      encoding: .utf8)

    let traceBranch = try #require(view.range(of: "if !evidence.traceParameters.isEmpty"))
    let typedInputs = try #require(view.range(of: "history.parameters.typedInputs"))
    #expect(traceBranch.lowerBound < typedInputs.lowerBound)
    #expect(view.contains("traceParameterTable(evidence.traceParameters)"))
    #expect(view.contains("Table(parameters)"))
    #expect(view.contains("parameter.comparison"))
    #expect(view.contains("typedParameterGrid(evidence.parameters)"))
    for key in [
      "history.parameters.column.before",
      "history.parameters.column.after",
      "history.parameters.column.status",
      "history.parameters.comparison.unchanged",
      "history.parameters.comparison.changed",
      "history.parameters.comparison.unverified",
    ] {
      #expect(localization.contains("\"\(key)\""), "missing localized key \(key)")
    }
    #expect(
      !localization.contains("history.parameters.comparison.restored"),
      "equal readbacks must not be promoted into a restore claim")
  }

  @Test func evidenceForAnotherJobOrOperationIsUnavailable() throws {
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
      Issue.record("mismatched evidence must not become available")
      return
    }
    #expect(reason.contains("did not match"))
    #expect(detail.evidence == nil)
  }

  @Test func oneMalformedArtifactFailsTheSectionWithoutPartialRows() throws {
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
      Issue.record("incomplete metadata must fail the complete Artifact section")
      return
    }
    #expect(reason.contains("incomplete"))
    #expect(detail.artifacts.isEmpty, "no partial Artifact row may survive")
  }

  // The App-facing surface has only bounded reads. If a mutating method is
  // ever added here it stops being a surface the sandboxed GUI may hold, so
  // the absence is pinned rather than assumed.
  @Test func theApplicationSurfaceExposesNoMutation() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(
          path: "Sources/ArkDeckClientKit/RuntimeHistoryApplicationFacade.swift"),
      encoding: .utf8)

    let protocolBody = try #require(
      source.range(of: "public protocol RuntimeHistoryApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    #expect(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count == 2,
      "the App-facing Runtime surface must expose only paged summary reads")
    #expect(protocolBody.contains("func refreshHistory()"))
    #expect(protocolBody.contains("func loadOlderHistory()"))

    let detailProtocolBody = try #require(
      source.range(of: "public protocol RuntimeJobDetailApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    #expect(
      detailProtocolBody.split(separator: "\n").filter { $0.contains("func ") }.count == 3,
      "the detail surface exposes only detail, bounded local preview and bounded export")
    #expect(detailProtocolBody.contains("func loadJobDetail("))
    #expect(detailProtocolBody.contains("func exportArtifact("))
    #expect(detailProtocolBody.contains("func readArtifact("))
    #expect(detailProtocolBody.contains("maximumBytes: Int"))
    #expect(detailProtocolBody.contains("allowSensitive: Bool"))

    // Only the read-only method may be named anywhere in this file: a
    // mutating method name appearing here would mean the App can compose a
    // frame the daemon's allowlist is the only thing refusing.
    for mutating in [
      "job.submit", "job.run", "job.cancel", "job.reconcile", "job.plan",
      "target.adopt", "artifact.import", "artifact.export",
    ] {
      #expect(
        !source.contains("\"\(mutating)"),
        "the App-facing facade must not be able to name \(mutating)")
    }
    #expect(source.contains("method: \"job.list\""))
    #expect(source.contains("\"order\": .string(\"createdAtDescJobIdAsc\")"))
    #expect(source.contains("\"includeTimeline\": .bool(false)"))
    #expect(source.contains("\"includeCurrent\": .bool(true)"))
    #expect(source.contains("RuntimeAppReadResources.jobDetail("))
    #expect(source.contains("request(\"job.evidence\""))
    #expect(source.contains("RuntimeAppReadResources.artifactInventory("))
    #expect(source.contains("method: \"artifact.read\""))
  }

  @Test func everyAppWorkspaceUsesTheBoundedRecentSummaryPolicy() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let clientKit = repository.appending(path: "Packages/ArkDeckKit/Sources/ArkDeckClientKit")
    for file in [
      "DebugApplicationFacade.swift", "TraceApplicationFacade.swift",
      "UIDumpApplicationFacade.swift",
    ] {
      let source = try String(contentsOf: clientKit.appending(path: file), encoding: .utf8)
      #expect(
        source.contains("params: RuntimeAppReadResources.recentSummaryParams"),
        "\(file) must not restore an unbounded startup history read")
    }
    let deviceList = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckClientKit/DeviceListApplicationFacade.swift"),
      encoding: .utf8)
    #expect(
      !deviceList.contains("method: \"job.list"),
      "device startup must use the daemon's compact projection, not read job history")
    let policy = try String(
      contentsOf: repository.appending(path: "Packages/ArkDeckKit/Sources/ArkDeckClientKit/RuntimeAppReadResources.swift"),
      encoding: .utf8)
    #expect(policy.contains("\"pageSize\": .integer(250)"))
    #expect(policy.contains("\"order\": .string(\"createdAtDescJobIdAsc\")"))
    #expect(policy.contains("\"includeTimeline\": .bool(false)"))
  }

  @Test func historyLoadsFullTimelineOnlyWithSelectedDetail() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/History/RuntimeHistoryView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/HistoryLocalizable.xcstrings"),
      encoding: .utf8)

    #expect(view.contains("detail.timelineAvailability"))
    #expect(view.contains("timelineEntries(detail.timeline, job: job)"))
    #expect(view.contains("presentation.hasOlderJobs"))
    #expect(view.contains("history.loadOlder"))
    #expect(view.contains("job.activityDate"))
    #expect(localization.contains("\"history.action.loadOlder\""))
  }

  @Test func historyActivityCenterClosesFilterCacheAndContextRegressions() throws {
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
      #expect(view.contains(".accessibilityIdentifier(\"\(identifier)\")"))
    }
    #expect(
      view.components(separatedBy: ".accessibilityIdentifier(\"history.filter.search\")").count
        - 1
        == 1,
      "wide and compact layouts must share one search field rather than duplicate state")
    #expect(view.contains("filterSidebar"))
    #expect(view.contains("compactFilters"))
    #expect(view.contains("filterPickers"))
    #expect(view.contains(".contentShape(.rect)"))

    #expect(
      !view.contains("@AppStorage"),
      "History saved filters must be owned by Runtime rather than the App container")
    #expect(view.contains("RuntimeHistoryFilterQuery("))
    #expect(view.contains("onSaveFilter?(currentFilterQuery)"))
    #expect(view.contains("history.filter.reloadSaved"))
    #expect(
      view.contains("let generation = savedFilterGeneration"),
      "a mutation must carry the generation the view last read from the owner")
    #expect(view.contains("expectedGeneration: generation"))
    #expect(view.contains("savedFilterGeneration = resource.generation"))
    #expect(
      view.components(separatedBy: "self.savedFilterRequestID == requestID").count - 1
        >= 3,
      "the load and both mutation legs must reject superseded replies")
    #expect(
      !view.contains("UserDefaults"),
      """
      the saved filter has one owner: reading it from this process's preferences is the \
      shape that let an old App-local value republish itself into the Runtime
      """)
    #expect(
      !view.contains("history.savedFilter"),
      "the retired App-local filter keys must not be read, written or removed here")
    #expect(
      view.contains("HistoryActivityFilter(rawValue: savedFilterQuery.activity) ?? .all"),
      "Runtime filters must restore normally and unknown values must fail to all")

    #expect(view.contains("detailGeneration &+= 1"))
    #expect(view.contains("self.detailsByJobID = [:]"))
    #expect(view.contains("func reloadDetail(jobID:"))
    #expect(
      view.contains(".onChange(of: isRefreshInFlight)"),
      "refresh must restart an invalidated detail even when the cache was already empty")
    #expect(view.contains("self.detailGeneration == generation"))
    #expect(view.contains("self.detailRequestIDs[jobID] == requestID"))
    let requestCheck = try #require(view.range(of: "self.detailRequestIDs[jobID] == requestID"))
    let loadingRemoval = try #require(view.range(of: "self.loadingDetailJobIDs.remove(jobID)"))
    #expect(
      requestCheck.lowerBound < loadingRemoval.lowerBound,
      "a superseded read must not clear the newer request's loading state")
    #expect(view.contains("case .loading:"))
    #expect(view.contains("history.loading"))

    let refresh = try #require(view.range(of: "  func refresh() {"))
    let loadOlder = try #require(view.range(of: "  func loadOlder() {"))
    let loadDetail = try #require(view.range(of: "  func loadDetail(jobID:"))
    let refreshBody = String(view[refresh.lowerBound..<loadOlder.lowerBound])
    let olderBody = String(view[loadOlder.lowerBound..<loadDetail.lowerBound])
    #expect(refreshBody.contains("historyGeneration &+= 1"))
    #expect(refreshBody.contains("isLoadOlderInFlight = false"))
    let generationGuard = try #require(
      olderBody.range(of: "self.historyGeneration == generation"))
    let spinnerReset = try #require(
      olderBody.range(of: "defer { self.isLoadOlderInFlight = false }"))
    let assignment = try #require(olderBody.range(of: "self.presentation = next"))
    #expect(generationGuard.lowerBound < spinnerReset.lowerBound)
    #expect(generationGuard.lowerBound < assignment.lowerBound)

    #expect(app.contains("RuntimeHistoryWorkspaceContext"))
    #expect(app.contains("HistoryWorkspaceContextBanner"))
    #expect(app.contains("openHistoryWorkspace"))
    #expect(app.contains("openHistoryContext(context)"))
    #expect(app.contains("historyContext: visibleHistoryContext"))
    #expect(
      !app.contains("HistoryWorkspaceDestination"),
      "History must pass exact record context rather than a destination-only navigation token")

    for key in [
      "history.activity.device", "history.activity.other",
      "history.activity.open.detailUnavailable", "history.activity.open.unsupported",
      "history.context.title", "history.context.readOnly", "history.detail.reload",
      "history.loading",
    ] {
      #expect(localization.contains("\"\(key)\""), "missing localized key \(key)")
    }
  }

  @Test func historicalWorkspaceReadsRejectSupersededPresentationResults() throws {
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
    #expect(viewer.contains("self.captureGeneration == generation"))
    #expect(viewer.contains("captureGeneration &+= 1"))
    #expect(viewer.contains("viewer.history.loading"))
    #expect(device.contains("self.screenGeneration == generation"))
    #expect(device.contains("adopted.filter { $0.adoptedTargetID == targetID }"))
    #expect(device.contains("liveness = DeviceFrameLiveness()"))
    #expect(trace.contains("viewerReadGeneration == generation"))
    #expect(trace.contains("self.viewerReadGeneration == viewerGenerationAtSubmission"))
  }

  @Test func debugArtifactRowsUseTheReviewedBoundedExporterInsteadOfAPlaceholderButton() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Debug/DebugWorkspaceView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/DebugLocalizable.xcstrings"),
      encoding: .utf8)

    #expect(view.contains("runtimeArtifactRows("))
    #expect(view.contains("model.exportArtifact("))
    #expect(view.contains(".confirmationDialog("))
    #expect(view.contains("allowSensitive: row.artifact.privacy == \"sensitive\""))
    #expect(view.contains("exportStatesByArtifactID"))
    #expect(
      !view.contains("Button(DebugL10n.text(\"debug.logs.export\")) {}"),
      "Debug must not regress to a permanently disabled export placeholder")
    #expect(
      !localization.contains("debug.blocked.artifactExport"),
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
