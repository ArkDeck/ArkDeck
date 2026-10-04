import ArkDeckCore
import Foundation

actor DiagnosticCaptureProvider: DiagnosticCaptureProviding {
  private let send: RuntimeAppReadResources.Send
  private let details: any RuntimeJobDetailApplicationProviding

  init(
    send: @escaping RuntimeAppReadResources.Send = { method, params in
      switch await RuntimeXPCRequestTransport.request(
        method: method, params: params, timeoutSeconds: method == "job.run" ? 660 : 120)
      {
      case .success(let data): return data
      case .failure(let error): throw DiagnosticCaptureFailure(error.message, uncertain: true)
      }
    },
    details: any RuntimeJobDetailApplicationProviding = RuntimeJobDetailApplicationFacade.make()
  ) {
    self.send = send
    self.details = details
  }

  func preflight(target: DeviceTargetPresentation) async throws {
    guard let bindingRevision = target.bindingRevision else {
      throw DiagnosticCaptureFailure("Adopted target has no binding revision")
    }
    let operations = try await result("operation.list", [:])
    guard case .array(let rows) = operations,
      let entry = rows.compactMap({ row -> [String: JSONValue]? in
        if case .object(let fields) = row { return fields }; return nil
      }).first(where: { $0["reference"] == .string(DiagnosticCaptureFacade.operationReference) }),
      entry["availability"] == .string("available")
    else { throw DiagnosticCaptureFailure("The installed Runtime does not offer Diagnostic Session capture") }
    let probeData = try await send("trace.probe", ["targetId": .string(target.id)])
    let probe = try TraceRuntimeProbeResponseDecoding.snapshot(
      .success(probeData), target: TraceTargetPresentation(
        id: target.id, bindingRevision: bindingRevision, toolVersion: "", adoptedAtUTC: "")).get()
    guard probe.adapterDisposition == "captureEligible", probe.supportedTags.contains("ohos") else {
      throw DiagnosticCaptureFailure("The selected device has no supported ohos trace adapter")
    }
    let quota = try await result("artifact.quota", [:])
    guard case .object(let fields) = quota, case .integer(let remaining)? = fields["remainingBytes"],
      remaining >= DiagnosticCaptureFacade.byteBudget else {
      throw DiagnosticCaptureFailure("Diagnostic Session needs at least 128 MiB of Artifact headroom")
    }
    let jobs = try await RuntimeAppReadResources.recentJobSummaries(
      send("job.list", RuntimeAppReadResources.recentSummaryParams))
    guard !jobs.contains(where: {
      $0["targetId"] as? String == target.id && !Self.terminal($0["state"] as? String ?? "")
    }) else { throw DiagnosticCaptureFailure("The selected device already has an unfinished Job") }
  }

  func submit(target: DeviceTargetPresentation, durationSeconds: Int) async throws -> String {
    let request = try DiagnosticCaptureFacade.request(
      target: target, durationSeconds: durationSeconds, nonce: UUID().uuidString.lowercased())
    let bytes = try CanonicalJSONEncoders.canonical().encode(request)
    let value = try await result("job.submit", ["requestJson": .string(String(decoding: bytes, as: UTF8.self))])
    guard case .object(let fields) = value, case .string(let id)? = fields["jobId"], !id.isEmpty else {
      throw DiagnosticCaptureFailure("Runtime accepted no identifiable Diagnostic Session", uncertain: true)
    }
    return id
  }

  func run(jobID: String) async throws { _ = try await result("job.run", ["jobId": .string(jobID)]) }

  func status(jobID: String, target: DeviceTargetPresentation) async throws -> DiagnosticCaptureSnapshot {
    try await snapshot("diagnostic.session.status", params: ["jobId": .string(jobID)], target: target)
  }

  func mark(jobID: String, markerID: String, target: DeviceTargetPresentation) async throws -> DiagnosticCaptureSnapshot {
    try await snapshot("diagnostic.session.mark", params: ["jobId": .string(jobID), "markerId": .string(markerID)], target: target)
  }

  func stop(jobID: String, target: DeviceTargetPresentation) async throws -> DiagnosticCaptureSnapshot {
    try await snapshot("diagnostic.session.stop", params: ["jobId": .string(jobID)], target: target)
  }

  func cancelPreparation(jobID: String) async throws {
    _ = try await result("job.cancel", ["jobId": .string(jobID)])
  }

  func history(jobID: String, target: DeviceTargetPresentation) async throws -> RuntimeHistoryWorkspaceContext {
    let status = try await RuntimeAppReadResources.statusPresentation(jobID: jobID, send: send)
    guard status["operation"] as? String == DiagnosticCaptureFacade.operationReference,
      status["targetId"] as? String == target.id, let state = status["state"] as? String,
      Self.terminal(state), let waiting = status["waitingForHuman"] as? Bool,
      let unknown = status["outcomeUnknown"] as? Bool,
      let residue = status["outstandingResidueCount"] as? Int else {
      throw DiagnosticCaptureFailure("Diagnostic Session history does not match the accepted Job")
    }
    let summary = RuntimeJobSummaryPresentation(
      id: jobID, operationReference: DiagnosticCaptureFacade.operationReference, targetID: target.id,
      state: state, waitingForHuman: waiting, outcomeUnknown: unknown, outstandingResidueCount: residue,
      timeline: status["timeline"] as? [String] ?? [], executionMode: status["executionMode"] as? String,
      sessionID: status["sessionId"] as? String, threadID: status["threadId"] as? String,
      workspaceKind: .diagnostics, finishedAtUTC: status["finishedAtUtc"] as? String)
    let detail = await details.loadJobDetail(jobID: jobID, operationReference: DiagnosticCaptureFacade.operationReference)
    guard let context = RuntimeHistoryWorkspaceContext(job: summary, detail: detail),
      context.bindingRevision == target.bindingRevision else {
      throw DiagnosticCaptureFailure("Diagnostic Session history is unavailable")
    }
    return context
  }

  private func snapshot(
    _ method: String, params: [String: JSONValue], target: DeviceTargetPresentation
  ) async throws -> DiagnosticCaptureSnapshot {
    let value = try await result(method, params)
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "jobId", "targetId", "bindingRevision", "state", "jobState",
        "outcomeUnknown", "controlAvailable", "maximumSeconds", "maximumMarkers", "elapsedMs",
        "stopRequested", "armedAtHostUTC", "endedAtHostUTC", "markers"],
      case .array(let marks)? = fields["markers"], marks.allSatisfy({ mark in
        guard case .object(let fields) = mark else { return false }
        return Set(fields.keys) == ["markerId", "atHostUTC", "offsetMs"]
          || Set(fields.keys) == ["markerId", "atHostUTC", "offsetMs", "label"]
      }) else { throw DiagnosticCaptureFailure("Runtime returned an unsupported session shape", uncertain: true) }
    let data = try CanonicalJSONEncoders.canonical().encode(value)
    let snapshot = try JSONDecoder().decode(DiagnosticCaptureSnapshot.self, from: data)
    guard case .string(let id)? = params["jobId"] else { throw DiagnosticCaptureFailure("Missing exact Job") }
    try snapshot.validate(jobID: id, target: target)
    return snapshot
  }

  private func result(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
    let bytes = try await send(method, params)
    let fields = try ControlFrameJSON.decodeObject(
      bytes.last == 0x0A ? Data(bytes.dropLast()) : bytes,
      maximumBytes: ArkDeckControlProtocol.maximumResponseFrameBytes)
    if fields["ok"] == .bool(true), let result = fields["result"] { return result }
    if case .object(let error)? = fields["error"], case .string(let message)? = error["message"] {
      throw DiagnosticCaptureFailure(message)
    }
    throw DiagnosticCaptureFailure("Runtime returned an unreadable session reply", uncertain: true)
  }

  private static func terminal(_ state: String) -> Bool {
    JobState(rawValue: state)?.isTerminal == true
  }
}
