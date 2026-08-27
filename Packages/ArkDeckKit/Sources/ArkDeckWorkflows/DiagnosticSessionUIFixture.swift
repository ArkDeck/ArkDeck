import ArkDeckCore
import Foundation

/// Reached only by the explicit History UI fixture provider. There is no
/// transport, filesystem input, capture or hardware evidence in this sample.
enum DiagnosticSessionUIFixture {
  static let job = RuntimeJobSummaryPresentation(
    id: "job-fixture-diagnostics", operationReference: "capture.diagnostics@1",
    targetID: "target-fixture-dayu200", state: "succeeded", waitingForHuman: false,
    outcomeUnknown: false, outstandingResidueCount: 0, timeline: ["queued", "running", "succeeded"],
    executionMode: "execute", sessionID: "session-fixture-diagnostics", threadID: "t-diagnostics-fixture",
    workspaceKind: .diagnostics, actualEffect: "readOnly", finishedAtUTC: "2026-08-27T08:00:10Z")

  static func documents() throws -> [String: Data] {
    func encode(_ value: Any) throws -> Data {
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    let log = Data("UI fixture only: bounded HiLog sample\n".utf8)
    let index: [String: Any] = [
      "operation": job.operationReference, "jobId": job.id,
      "artifacts": [
        "hilog.txt": ["status": "published", "required": false, "artifactId": "fixture-hilog.txt",
          "byteCount": log.count, "sha256": SHA256Hex.string(of: log)],
        "trace.htrace": ["status": "missing", "required": false, "detail": "not selected"],
      ],
    ]
    var summary = index
    summary["completeness"] = "complete"
    summary["missingRequired"] = [String]()
    return [
      "hilog.txt": log,
      "capture.log": Data("UI fixture only\nqueued\nrunning\nsucceeded\n".utf8),
      "artifact-index.json": try encode(index), "capture-summary.json": try encode(summary),
      "markers.json": try encode([
        "documentType": "arkdeck-diagnostic-markers", "schemaVersion": "1.0.0", "jobId": job.id,
        "markers": [["kind": "auto", "trigger": "stepFailed", "detail": "UI sample marker; not hardware evidence"]],
        "notDerived": [["kind": "frameDeadline", "reason": "not inspected"], ["kind": "logKeyword", "reason": "not inspected"]],
      ]),
    ]
  }

  static func detail() throws -> RuntimeJobDetailPresentation {
    func response(_ value: Any) throws -> RuntimeHistoryTransportResult {
      .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": value], options: [.sortedKeys]))
    }
    let docs = try documents()
    let inventory: [[String: Any]] = docs.keys.sorted().map { name in
      let bytes = docs[name]!
      return [
        "jobId": job.id, "artifactId": "fixture-\(name)", "name": name,
        "role": name == "hilog.txt" ? "raw" : name == "capture.log" ? "log" : "derived",
        "mediaType": name.hasSuffix("json") ? "application/json" : "text/plain",
        "byteCount": bytes.count, "sha256": SHA256Hex.string(of: bytes),
        "privacy": name == "hilog.txt" ? "sensitive" : "standard", "status": "published",
        "sourceOperation": job.operationReference, "createdAtUtc": "2026-08-27T08:00:10Z", "redactionApplied": true,
      ]
    }
    return RuntimeJobDetailResponseDecoding.presentation(
      jobID: job.id, operationReference: job.operationReference,
      statusResponse: try response([
        "jobId": job.id, "operation": job.operationReference, "targetId": job.targetID,
        "sessionId": job.sessionID!, "timeline": job.timeline,
      ]),
      evidenceResponse: try response([
        "jobId": job.id, "operationReference": job.operationReference,
        "catalogDigest": String(repeating: "a", count: 64), "providerId": "hdc",
        "executionMode": "execute", "terminalState": "succeeded", "actualEffect": "readOnly",
        "bindingRevision": 3,
        "parameters": ["durationSeconds": 10, "captureHilog": true, "uiDump": false] as [String: Any],
      ]),
      artifactResponse: try response(inventory))
  }
}
