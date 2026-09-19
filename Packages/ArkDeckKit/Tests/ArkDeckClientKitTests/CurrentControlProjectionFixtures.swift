import Foundation

// Local wire fixtures for the independent ClientKit behavior target.
/// Current transport envelope for presentation tests. Individual tests own the
/// job fields, including malformed rows used to verify fail-closed decoding.
func currentJobPageResponse(_ rows: [[String: Any]], cursor: String? = nil) throws -> Data {
  let items = rows.map { row in
    var current = row
    current["schemaVersion"] = "arkdeck.job-summary/1"
    if let timeline = current["timeline"] as? [String] {
      current["timeline"] = ["kind": "inline", "entries": timeline]
    }
    return current
  }
  return try JSONSerialization.data(withJSONObject: [
    "id": "fixture", "ok": true,
    "result": [
      "schemaVersion": "arkdeck.cli.page/1", "pageKind": "snapshot",
      "items": items, "order": "createdAtDescJobIdAsc",
      "snapshotRevision": "11111111-1111-4111-8111-111111111111",
      "hasMore": cursor != nil, "nextCursor": cursor as Any? ?? NSNull(),
    ],
  ])
}

func currentJobDetailResponse(_ job: [String: Any]) throws -> Data {
  var summary = job
  summary.removeValue(forKey: "timeline")
  summary["schemaVersion"] = "arkdeck.job-status/1"
  return try JSONSerialization.data(withJSONObject: ["id": "fixture", "ok": true, "result": [
    "schemaVersion": "arkdeck.job/1", "job": summary,
    "timeline": ["kind": "inline", "entries": job["timeline"] ?? []],
  ]])
}

func currentArtifactPageResponse(_ rows: [[String: Any]]) throws -> Data {
  let items = rows.map { row in
    var artifact = row
    artifact["schemaVersion"] = "arkdeck.artifact/1"
    artifact["owner"] = ["kind": "job", "id": artifact.removeValue(forKey: "jobId") ?? "job-1"]
    artifact["artifactDigest"] = artifact.removeValue(forKey: "sha256") ?? NSNull()
    artifact.removeValue(forKey: "statusDetail")
    artifact["lease"] = NSNull()
    artifact["providerId"] = "fixture"
    artifact["retention"] = ["class": "default", "pinned": false, "deadlineUtc": NSNull()]
    artifact["binding"] = ["targetId": "target-fixture", "bindingRevision": NSNull(), "stableIdentitySha256": NSNull()]
    artifact["observationWindow"] = NSNull()
    return artifact
  }
  return try JSONSerialization.data(withJSONObject: ["id": "fixture", "ok": true, "result": [
    "schemaVersion": "arkdeck.cli.page/1", "pageKind": "snapshot", "items": items,
    "order": "createdAtDescArtifactIdAsc", "snapshotRevision": "11111111-1111-4111-8111-111111111111",
    "hasMore": false, "nextCursor": NSNull(),
  ]])
}
