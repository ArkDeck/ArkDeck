import Foundation

/// Explicit UI automation only; never composed by a normal launch and never
/// submitted to a Runtime or presented as hardware evidence.
public enum DiagnosticCaptureUIFixture {
  public static func provider(arguments: [String] = ProcessInfo.processInfo.arguments) -> (any DiagnosticCaptureProviding)? {
    arguments.contains("--ui-test-diagnostic-capture") ? Provider() : nil
  }

  private actor Provider: DiagnosticCaptureProviding {
    private var target: DeviceTargetPresentation?
    private var seconds = 60
    private var ready = false
    private var stopped = false
    private var marks: [String] = []

    func preflight(target: DeviceTargetPresentation) {}
    func submit(target: DeviceTargetPresentation, durationSeconds: Int) -> String {
      self.target = target; seconds = durationSeconds; ready = false; stopped = false; marks = []
      return "job-ui-diagnostic-capture"
    }
    func run(jobID: String) { ready = true }
    func status(jobID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
      try snapshot(jobID: jobID)
    }
    func mark(jobID: String, markerID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
      marks.append(markerID)
      return try snapshot(jobID: jobID)
    }
    func stop(jobID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
      stopped = true
      return try snapshot(jobID: jobID)
    }
    func cancelPreparation(jobID: String) { stopped = true }
    func history(jobID: String, target: DeviceTargetPresentation) throws -> RuntimeHistoryWorkspaceContext {
      throw DiagnosticCaptureFailure("UI fixture has no published artifacts")
    }
    private func snapshot(jobID: String) throws -> DiagnosticCaptureSnapshot {
      let value: [String: Any] = [
        "schemaVersion": "1.0.0", "jobId": jobID, "targetId": target?.id ?? "missing",
        "bindingRevision": target?.bindingRevision ?? -1,
        "state": stopped ? "closed" : ready ? "recording" : "preparing",
        "jobState": stopped ? "succeeded" : "running", "outcomeUnknown": false,
        "controlAvailable": ready && !stopped, "maximumSeconds": seconds, "maximumMarkers": 50,
        "elapsedMs": stopped ? 1000 : 0, "stopRequested": stopped,
        "armedAtHostUTC": ready ? "2026-10-04T00:00:00Z" : NSNull(),
        "endedAtHostUTC": stopped ? "2026-10-04T00:00:01Z" : NSNull(),
        "markers": marks.map { ["markerId": $0, "atHostUTC": "2026-10-04T00:00:00Z", "offsetMs": 0] as [String: Any] },
      ]
      return try JSONDecoder().decode(DiagnosticCaptureSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
  }
}
