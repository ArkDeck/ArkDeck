// App-facing Runtime history, over the daemon's read-only XPC door.
//
// Same shape as HDCApplicationDiagnosticsFacade: the App receives closed
// presentation values and explicit refresh actions, and has no client, no
// socket, no argv and no way to submit anything. The transport speaks only
// the read-only allowlist the daemon enforces on its side, so even a defect
// here cannot produce a device effect.
//
// Everything that is not a understood, complete answer becomes an explicit
// `unavailable` reason the UI can state. There is deliberately no fallback,
// no cached last-good value and no partial render.

import ArkDeckCore
import CryptoKit
import Foundation
import os

public enum RuntimeHistoryAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)
}

/// One Runtime job as the App may see it. Every field is a fact the daemon
/// reported; none of them can be minted on this side.
public struct RuntimeJobSummaryPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let operationReference: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let outstandingResidueCount: Int
  public let timeline: [String]
  public let executionMode: String?
  public let sessionID: String?
  public let actualEffect: String?
  public let createdAtUTC: String?
  public let startedAtUTC: String?
  public let finishedAtUTC: String?
  public let supersededByRecoveryEpochID: String?
  public let recoveryEpochID: String?
  public let resolvedByTargetAliasResolutionID: String?
  public let activityDate: Date?

  public init(
    id: String, operationReference: String, targetID: String, state: String,
    waitingForHuman: Bool, outcomeUnknown: Bool, outstandingResidueCount: Int,
    timeline: [String], executionMode: String? = nil, sessionID: String? = nil,
    actualEffect: String? = nil,
    createdAtUTC: String? = nil, startedAtUTC: String? = nil, finishedAtUTC: String? = nil,
    supersededByRecoveryEpochID: String? = nil, recoveryEpochID: String? = nil,
    resolvedByTargetAliasResolutionID: String? = nil
  ) {
    self.id = id
    self.operationReference = operationReference
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.outstandingResidueCount = outstandingResidueCount
    self.timeline = timeline
    self.executionMode = executionMode
    self.sessionID = sessionID
    self.actualEffect = actualEffect
    self.createdAtUTC = createdAtUTC
    self.startedAtUTC = startedAtUTC
    self.finishedAtUTC = finishedAtUTC
    self.supersededByRecoveryEpochID = supersededByRecoveryEpochID
    self.recoveryEpochID = recoveryEpochID
    self.resolvedByTargetAliasResolutionID = resolvedByTargetAliasResolutionID
    activityDate = Self.parseUTC(finishedAtUTC ?? startedAtUTC ?? createdAtUTC)
  }

  private static func parseUTC(_ value: String?) -> Date? {
    guard let value else { return nil }
    return ISO8601Timestamps.parse(value)
  }

  /// Runtime has durable evidence that a later, distinct action established
  /// the current target epoch. The original Job and its unknown outcome stay
  /// untouched for audit; this relation only answers whether it still needs a
  /// current operator action.
  public var hasEstablishedCurrentEpoch: Bool {
    supersededByRecoveryEpochID != nil || resolvedByTargetAliasResolutionID != nil
  }

  /// An unknown outcome is never folded into a terminal state. Once Runtime
  /// establishes the current epoch, however, that historical unknown is no
  /// longer a current attention item.
  public var needsAttention: Bool {
    !hasEstablishedCurrentEpoch && (outcomeUnknown || waitingForHuman)
  }

  /// The global banner is reserved for unresolved work the operator can act
  /// on now. Historical unknowns with an exact Runtime resolution relation
  /// remain visible in History but must not keep paging the operator.
  public var requiresRecoveryGuidance: Bool {
    guard !hasEstablishedCurrentEpoch else { return false }
    if needsAttention { return true }
    guard let state = JobState(rawValue: state) else { return false }
    switch state {
    case .waitingForRecovery, .awaitingRebindConfirmation, .resumeAtConfirmedSafeBoundary,
      .userAbandonRequested:
      return true
    default:
      return false
    }
  }

  /// A nonterminal state represents current work only while it still belongs
  /// to the current target epoch and does not require recovery guidance.
  /// Runtime deliberately keeps historical unknown states nonterminal for
  /// audit, so checking `state` alone would render an old Flash as running.
  public var isCurrentActivity: Bool {
    guard !hasEstablishedCurrentEpoch, !requiresRecoveryGuidance,
      let state = JobState(rawValue: state)
    else { return false }
    return !state.isTerminal
  }
}

public struct RuntimeHistoryPresentation: Sendable, Equatable {
  public let availability: RuntimeHistoryAvailability
  public let jobs: [RuntimeJobSummaryPresentation]
  public let hasOlderJobs: Bool
  public let olderJobsLoadFailure: String?

  public init(
    availability: RuntimeHistoryAvailability,
    jobs: [RuntimeJobSummaryPresentation],
    hasOlderJobs: Bool = false,
    olderJobsLoadFailure: String? = nil
  ) {
    self.availability = availability
    self.jobs = jobs
    self.hasOlderJobs = hasOlderJobs
    self.olderJobsLoadFailure = olderJobsLoadFailure
  }

  public static let loading = RuntimeHistoryPresentation(
    availability: .unavailable(reason: "Runtime history is loading"), jobs: [])

  static func unavailable(_ reason: String) -> RuntimeHistoryPresentation {
    RuntimeHistoryPresentation(availability: .unavailable(reason: reason), jobs: [])
  }
}

public enum RuntimeJobDetailSectionAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)
}

public struct RuntimeJobParameterPresentation: Sendable, Equatable, Identifiable {
  public let name: String
  public let value: String
  public var id: String { name }
}

public struct RuntimeTraceParameterPresentation: Sendable, Equatable, Identifiable {
  public let name: String
  public let beforeState: String
  public let beforeValue: String?
  public let afterState: String
  public let afterValue: String?
  public var id: String { name }

  /// This is deliberately a comparison, not a restore verdict. The current
  /// Trace operation reads these parameters before and after capture but does
  /// not write them, so equal observations prove only that they did not
  /// change during this Job. An unreadable endpoint cannot prove equality.
  public var comparison: RuntimeTraceParameterComparison {
    guard beforeState != "unreadable", afterState != "unreadable",
      ["value", "missing"].contains(beforeState),
      ["value", "missing"].contains(afterState)
    else { return .unverified }
    return beforeState == afterState && beforeValue == afterValue
      ? .unchanged : .changed
  }
}

public enum RuntimeTraceParameterComparison: String, Sendable, Equatable {
  case unchanged
  case changed
  case unverified
}

public struct RuntimeJobEvidencePresentation: Sendable, Equatable {
  public let catalogDigest: String
  public let bindingRevision: Int?
  public let providerID: String
  public let actualEffect: String?
  public let executionMode: String
  public let terminalState: String
  public let startedAtUTC: String?
  public let firstEvidenceStepAtUTC: String?
  public let finishedAtUTC: String?
  public let parameters: [RuntimeJobParameterPresentation]
  public let parametersWereReported: Bool
  public let actualStepKinds: [String]
  public let authorityKind: String?
  public let authorityReference: String?
  public let observedModel: String?
  public let observedFirmware: String?
  public let observedTransport: String?
  public let observedBindingRevision: Int?
  public let traceTags: [String]
  public let traceParameters: [RuntimeTraceParameterPresentation]
  public let blockers: [String]
}

public struct RuntimeArtifactPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let role: String?
  public let mediaType: String
  public let byteCount: Int64
  public let sha256: String
  public let privacy: String
  public let status: String
  public let statusDetail: String?
  public let sourceOperation: String
  public let createdAtUTC: String
  public let redactionApplied: Bool
}

public struct RuntimeJobDetailPresentation: Sendable, Equatable {
  public let jobID: String
  public let timelineAvailability: RuntimeJobDetailSectionAvailability
  public let timeline: [String]
  public let evidenceAvailability: RuntimeJobDetailSectionAvailability
  public let evidence: RuntimeJobEvidencePresentation?
  public let artifactAvailability: RuntimeJobDetailSectionAvailability
  public let artifacts: [RuntimeArtifactPresentation]
}

public enum RuntimeArtifactExportResult: Sendable, Equatable {
  case completed(URL)
  case failed(String)
}

/// Closed App-facing surface. It exposes only bounded summary reads and no
/// submit, run, cancel, reconcile, adopt or import method to call.
public protocol RuntimeHistoryApplicationProviding: Sendable {
  func refreshHistory() async -> RuntimeHistoryPresentation
  func loadOlderHistory() async -> RuntimeHistoryPresentation
}

extension RuntimeHistoryApplicationProviding {
  public func loadOlderHistory() async -> RuntimeHistoryPresentation {
    await refreshHistory()
  }
}

/// A second closed reader keeps on-demand detail separate from the global
/// summary refresh. Export reads only one metadata-bound Artifact through a
/// bounded chunk method and writes it in the App process to a user-selected
/// URL; the destination path never crosses the daemon boundary.
public protocol RuntimeJobDetailApplicationProviding: Sendable {
  func loadJobDetail(
    jobID: String,
    operationReference: String
  ) async -> RuntimeJobDetailPresentation
  func exportArtifact(
    jobID: String,
    artifact: RuntimeArtifactPresentation,
    destinationURL: URL,
    allowSensitive: Bool
  ) async -> RuntimeArtifactExportResult
}

public enum RuntimeHistoryApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any RuntimeHistoryApplicationProviding {
    guard arguments.contains("--ui-test-runtime-history") else {
      return RuntimeHistoryXPCProvider()
    }
    return RuntimeHistoryFixtureProvider(arguments: arguments)
  }
}

public enum RuntimeJobDetailApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any RuntimeJobDetailApplicationProviding {
    if arguments.contains("--ui-test-runtime-history")
      || arguments.contains("--ui-test-flash")
      || arguments.contains("--ui-test-flash-plan")
    {
      return RuntimeJobDetailFixtureProvider()
    }
    return RuntimeJobDetailXPCProvider()
  }
}

/// Production transport. The Unix socket is unreachable from an App Sandbox
/// container, so this speaks the daemon's Mach service instead; when launchd
/// is not vending it the connection simply never answers and this reports an
/// accurate reason rather than pretending the history is empty.
private actor RuntimeHistoryXPCProvider: RuntimeHistoryApplicationProviding {
  private static let pageSize = 200
  private var loadedJobs: [RuntimeJobSummaryPresentation] = []
  private var nextCursor: String?

  func refreshHistory() async -> RuntimeHistoryPresentation {
    loadedJobs = []
    nextCursor = nil
    return await loadPage(cursor: nil)
  }

  func loadOlderHistory() async -> RuntimeHistoryPresentation {
    guard let nextCursor else {
      return RuntimeHistoryPresentation(availability: .available, jobs: loadedJobs)
    }
    return await loadPage(cursor: nextCursor)
  }

  private func loadPage(cursor: String?) async -> RuntimeHistoryPresentation {
    var params: [String: JSONValue] = [
      "pageSize": .integer(Int64(Self.pageSize)),
      "order": .string("newestFirst"),
      "includeTimeline": .bool(false),
    ]
    if let cursor {
      params["cursor"] = .string(cursor)
    } else {
      params["includeCurrent"] = .bool(true)
    }
    let response = await RuntimeHistoryXPCReadTransport.request(
      method: "job.list-page", params: params)
    switch response {
    case .failure(let reason):
      guard !loadedJobs.isEmpty else { return .unavailable(reason) }
      return RuntimeHistoryPresentation(
        availability: .available, jobs: loadedJobs, hasOlderJobs: true,
        olderJobsLoadFailure: reason)
    case .success(let data):
      switch RuntimeHistoryResponseDecoding.page(from: data) {
      case .unavailable(let reason):
        guard !loadedJobs.isEmpty else { return .unavailable(reason) }
        return RuntimeHistoryPresentation(
          availability: .available, jobs: loadedJobs, hasOlderJobs: true,
          olderJobsLoadFailure: reason)
      case .available(let jobs, let cursor):
        var known = Set(loadedJobs.map(\.id))
        loadedJobs.append(contentsOf: jobs.filter { known.insert($0.id).inserted })
        nextCursor = cursor
        return RuntimeHistoryPresentation(
          availability: .available, jobs: loadedJobs, hasOlderJobs: cursor != nil)
      }
    }
  }
}

private actor RuntimeJobDetailXPCProvider: RuntimeJobDetailApplicationProviding {
  func loadJobDetail(
    jobID: String,
    operationReference: String
  ) async -> RuntimeJobDetailPresentation {
    async let status = RuntimeHistoryXPCReadTransport.request(
      method: "job.status", params: ["jobId": .string(jobID)])
    async let evidence = RuntimeHistoryXPCReadTransport.request(
      method: "job.evidence", params: ["jobId": .string(jobID)])
    async let artifacts = RuntimeHistoryXPCReadTransport.request(
      method: "artifact.list", params: ["jobId": .string(jobID)])
    return await RuntimeJobDetailResponseDecoding.presentation(
      jobID: jobID,
      operationReference: operationReference,
      statusResponse: await status,
      evidenceResponse: evidence,
      artifactResponse: artifacts)
  }

  func exportArtifact(
    jobID: String,
    artifact: RuntimeArtifactPresentation,
    destinationURL: URL,
    allowSensitive: Bool
  ) async -> RuntimeArtifactExportResult {
    guard artifact.status == "published" else {
      return .failed("Only a published Artifact can be exported")
    }
    guard artifact.byteCount >= 0, artifact.byteCount <= Int64(Int.max) else {
      return .failed("Artifact byte count is outside this host's export range")
    }
    guard artifact.privacy != "sensitive" || allowSensitive else {
      return .failed("Sensitive Artifact export requires explicit opt-in")
    }
    let gainedScope = destinationURL.startAccessingSecurityScopedResource()
    defer {
      if gainedScope { destinationURL.stopAccessingSecurityScopedResource() }
    }
    let temporaryURL = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-artifact-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: temporaryURL)
    else {
      return .failed("The App could not create a bounded export staging file")
    }
    var handleIsOpen = true
    defer {
      if handleIsOpen { try? handle.close() }
    }

    do {
      var offset: Int64 = 0
      var digest = SHA256()
      let expectedCount = artifact.byteCount
      while offset < expectedCount {
        let response = await RuntimeHistoryXPCReadTransport.request(
          method: "artifact.read",
          params: [
            "jobId": .string(jobID),
            "artifactId": .string(artifact.id),
            "offset": .integer(offset),
            "maxBytes": .integer(256 * 1_024),
            "allowSensitive": .bool(allowSensitive),
          ])
        let chunk = try RuntimeArtifactChunkResponseDecoding.chunk(
          response,
          jobID: jobID,
          artifact: artifact,
          expectedOffset: offset)
        guard !chunk.data.isEmpty else {
          throw RuntimeArtifactExportFailure(
            message: "Runtime returned an empty non-terminal Artifact chunk")
        }
        try handle.write(contentsOf: chunk.data)
        digest.update(data: chunk.data)
        offset = chunk.nextOffset
        guard chunk.eof == (offset == expectedCount) else {
          throw RuntimeArtifactExportFailure(
            message: "Runtime Artifact end-of-file facts drifted during export")
        }
      }
      try handle.synchronize()
      try handle.close()
      handleIsOpen = false
      let actualSHA256 = SHA256Hex.hexString(digest.finalize())
      guard actualSHA256 == artifact.sha256 else {
        throw RuntimeArtifactExportFailure(
          message: "Exported Artifact SHA-256 does not match Runtime metadata")
      }

      if FileManager.default.fileExists(atPath: destinationURL.path) {
        let values = try destinationURL.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw RuntimeArtifactExportFailure(
            message: "The selected export destination is not a regular file")
        }
        _ = try FileManager.default.replaceItemAt(
          destinationURL, withItemAt: temporaryURL)
      } else {
        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
      }
      return .completed(destinationURL)
    } catch let failure as RuntimeArtifactExportFailure {
      return .failed(failure.message)
    } catch {
      return .failed("Artifact export failed: \(error)")
    }
  }
}

private struct RuntimeArtifactExportFailure: Error {
  let message: String
}

private enum RuntimeArtifactChunkResponseDecoding {
  struct Chunk {
    let data: Data
    let nextOffset: Int64
    let eof: Bool
  }

  static func chunk(
    _ response: RuntimeHistoryTransportResult,
    jobID _: String,
    artifact: RuntimeArtifactPresentation,
    expectedOffset: Int64
  ) throws -> Chunk {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let reason): throw RuntimeArtifactExportFailure(message: reason)
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw RuntimeArtifactExportFailure(message: "Runtime returned an unreadable Artifact chunk")
    }
    if let error = envelope["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      throw RuntimeArtifactExportFailure(
        message: "Runtime refused Artifact export: \(code) — \(message)")
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any],
      result["artifactId"] as? String == artifact.id,
      let offset = int64(result["offset"]), offset == expectedOffset,
      let nextOffset = int64(result["nextOffset"]), nextOffset > offset,
      let total = int64(result["totalByteCount"]), total == artifact.byteCount,
      let byteCount = int64(result["byteCount"]), byteCount == nextOffset - offset,
      let encoded = result["base64"] as? String,
      let bytes = Data(base64Encoded: encoded), Int64(bytes.count) == byteCount,
      let eof = result["eof"] as? Bool,
      nextOffset <= artifact.byteCount
    else {
      throw RuntimeArtifactExportFailure(
        message: "Runtime returned incomplete or drifting Artifact chunk facts")
    }
    return Chunk(data: bytes, nextOffset: nextOffset, eof: eof)
  }

  private static func int64(_ value: Any?) -> Int64? {
    switch value {
    case let number as NSNumber: return number.int64Value
    case let value as Int: return Int64(value)
    case let value as Int64: return value
    default: return nil
    }
  }
}

enum RuntimeHistoryTransportResult: Sendable {
  case success(Data)
  case failure(String)
}

private enum RuntimeHistoryXPCReadTransport {
  static func request(
    method: String,
    params: [String: JSONValue]? = nil
  ) async -> RuntimeHistoryTransportResult {
    let frame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params)
    } catch {
      return .failure("Could not compose a Runtime read request")
    }
    return await send(frame)
  }

  private static func send(_ frame: Data) async -> RuntimeHistoryTransportResult {
    await withCheckedContinuation { continuation in
      // NSXPCConnection predates Sendable and is safe to message from any
      // thread; the box carries that fact rather than widening the actor.
      let box = XPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()

      // Exactly one resume: an interruption and a reply can both arrive, and
      // resuming a continuation twice is a crash, not a recoverable error.
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: RuntimeHistoryTransportResult) {
        let alreadyAnswered = answered.withLock { state -> Bool in
          if state { return true }
          state = true
          return false
        }
        guard !alreadyAnswered else { return }
        box.connection.invalidate()
        continuation.resume(returning: result)
      }

      let proxy =
        connection.remoteObjectProxyWithErrorHandler { error in
          finish(
            .failure(
              "ArkDeck Runtime is not reachable: \(error.localizedDescription)"))
        } as? ArkDeckAgentXPCProtocol

      guard let proxy else {
        finish(.failure("ArkDeck Runtime is not reachable"))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure("The Runtime transport refused this request: \(refusal)"))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure("The Runtime transport returned neither a response nor a reason"))
        }
      }
    }
  }
}

/// Response decoding, separated from the transport so the contract that
/// matters can be pinned directly: what the App is allowed to conclude
/// from a given daemon answer.
enum RuntimeHistoryResponseDecoding {
  enum PageResult {
    case available([RuntimeJobSummaryPresentation], nextCursor: String?)
    case unavailable(String)
  }

  /// Anything the daemon did not answer completely is unavailable, not an
  /// empty history: "no jobs" and "could not read jobs" must never render the
  /// same way.
  static func presentation(from data: Data) -> RuntimeHistoryPresentation {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .unavailable("ArkDeck Runtime returned an unreadable response")
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .unavailable("ArkDeck Runtime refused the request: \(code) — \(message)")
    }
    guard object["ok"] as? Bool == true, let result = object["result"] as? [[String: Any]] else {
      return .unavailable("ArkDeck Runtime returned no job list")
    }
    return presentation(entries: result)
  }

  static func page(from data: Data) -> PageResult {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .unavailable("ArkDeck Runtime returned an unreadable history page")
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .unavailable("ArkDeck Runtime refused the history page: \(code) — \(message)")
    }
    guard object["ok"] as? Bool == true,
      let result = object["result"] as? [String: Any],
      let entries = result["jobs"] as? [[String: Any]]
    else {
      return .unavailable("ArkDeck Runtime returned no paged job list")
    }
    let currentEntries: [[String: Any]]
    if let supplied = result["currentJobs"] {
      guard let values = supplied as? [[String: Any]] else {
        return .unavailable("ArkDeck Runtime returned an invalid current Job list")
      }
      currentEntries = values
    } else {
      currentEntries = []
    }
    var combinedEntries = currentEntries
    var knownIDs = Set(currentEntries.compactMap { $0["jobId"] as? String })
    combinedEntries.append(
      contentsOf: entries.filter { entry in
        guard let jobID = entry["jobId"] as? String else { return true }
        return knownIDs.insert(jobID).inserted
      })
    let presentation = presentation(entries: combinedEntries)
    guard case .available = presentation.availability else {
      if case .unavailable(let reason) = presentation.availability {
        return .unavailable(reason)
      }
      return .unavailable("ArkDeck Runtime returned an unreadable history page")
    }
    let nextCursor: String?
    if result["nextCursor"] is NSNull || result["nextCursor"] == nil {
      nextCursor = nil
    } else if let value = result["nextCursor"] as? String {
      nextCursor = value
    } else {
      return .unavailable("ArkDeck Runtime returned an invalid history cursor")
    }
    return .available(presentation.jobs, nextCursor: nextCursor)
  }

  private static func presentation(
    entries: [[String: Any]]
  ) -> RuntimeHistoryPresentation {
    var jobs: [RuntimeJobSummaryPresentation] = []
    for entry in entries {
      guard
        let id = entry["jobId"] as? String,
        let operation = entry["operation"] as? String,
        let target = entry["targetId"] as? String,
        let state = entry["state"] as? String
      else {
        return .unavailable("ArkDeck Runtime returned a job without its identifying facts")
      }
      jobs.append(
        RuntimeJobSummaryPresentation(
          id: id,
          operationReference: operation,
          targetID: target,
          state: state,
          waitingForHuman: entry["waitingForHuman"] as? Bool ?? false,
          outcomeUnknown: entry["outcomeUnknown"] as? Bool ?? false,
          outstandingResidueCount: entry["outstandingResidueCount"] as? Int ?? 0,
          timeline: entry["timeline"] as? [String] ?? [],
          executionMode: entry["executionMode"] as? String,
          sessionID: entry["sessionId"] as? String,
          actualEffect: entry["actualEffect"] as? String,
          createdAtUTC: entry["createdAtUtc"] as? String,
          startedAtUTC: entry["startedAtUtc"] as? String,
          finishedAtUTC: entry["finishedAtUtc"] as? String,
          supersededByRecoveryEpochID: entry["supersededByRecoveryEpochId"] as? String,
          recoveryEpochID: entry["recoveryEpochId"] as? String,
          resolvedByTargetAliasResolutionID: entry[
            "resolvedByTargetAliasResolutionId"] as? String))
    }
    return RuntimeHistoryPresentation(availability: .available, jobs: jobs)
  }
}

enum RuntimeJobDetailResponseDecoding {
  private enum Section<Value> {
    case available(Value)
    case unavailable(String)
  }

  static func presentation(
    jobID: String,
    operationReference: String,
    statusResponse: RuntimeHistoryTransportResult? = nil,
    evidenceResponse: RuntimeHistoryTransportResult,
    artifactResponse: RuntimeHistoryTransportResult
  ) -> RuntimeJobDetailPresentation {
    let timeline = decodeTimeline(
      jobID: jobID,
      operationReference: operationReference,
      response: statusResponse)
    let evidence = decodeEvidence(
      jobID: jobID,
      operationReference: operationReference,
      response: evidenceResponse)
    let artifacts = decodeArtifacts(
      jobID: jobID,
      operationReference: operationReference,
      response: artifactResponse)

    let timelineAvailability: RuntimeJobDetailSectionAvailability
    let timelineValue: [String]
    switch timeline {
    case .available(let value):
      timelineAvailability = .available
      timelineValue = value
    case .unavailable(let reason):
      timelineAvailability = .unavailable(reason: reason)
      timelineValue = []
    }

    let evidenceAvailability: RuntimeJobDetailSectionAvailability
    let evidenceValue: RuntimeJobEvidencePresentation?
    switch evidence {
    case .available(let value):
      evidenceAvailability = .available
      evidenceValue = value
    case .unavailable(let reason):
      evidenceAvailability = .unavailable(reason: reason)
      evidenceValue = nil
    }

    let artifactAvailability: RuntimeJobDetailSectionAvailability
    let artifactValues: [RuntimeArtifactPresentation]
    switch artifacts {
    case .available(let values):
      artifactAvailability = .available
      artifactValues = values
    case .unavailable(let reason):
      artifactAvailability = .unavailable(reason: reason)
      artifactValues = []
    }

    return RuntimeJobDetailPresentation(
      jobID: jobID,
      timelineAvailability: timelineAvailability,
      timeline: timelineValue,
      evidenceAvailability: evidenceAvailability,
      evidence: evidenceValue,
      artifactAvailability: artifactAvailability,
      artifacts: artifactValues)
  }

  private static func decodeTimeline(
    jobID: String,
    operationReference: String,
    response: RuntimeHistoryTransportResult?
  ) -> Section<[String]> {
    guard let response else {
      return .unavailable("This detail reader did not request the Job timeline")
    }
    let value: [String: Any]
    switch response {
    case .failure(let reason): return .unavailable(reason)
    case .success(let data):
      switch resultObject(from: data, label: "Job status") {
      case .available(let result): value = result
      case .unavailable(let reason): return .unavailable(reason)
      }
    }
    guard value["jobId"] as? String == jobID,
      value["operation"] as? String == operationReference,
      let timeline = value["timeline"] as? [String]
    else {
      return .unavailable("Job status did not match the selected Job")
    }
    return .available(timeline)
  }

  private static func decodeEvidence(
    jobID: String,
    operationReference: String,
    response: RuntimeHistoryTransportResult
  ) -> Section<RuntimeJobEvidencePresentation> {
    let envelope: [String: Any]
    switch response {
    case .failure(let reason): return .unavailable(reason)
    case .success(let data):
      switch resultObject(from: data, label: "Job evidence") {
      case .available(let value): envelope = value
      case .unavailable(let reason): return .unavailable(reason)
      }
    }
    guard
      envelope["jobId"] as? String == jobID,
      envelope["operationReference"] as? String == operationReference,
      let catalogDigest = envelope["catalogDigest"] as? String,
      let providerID = envelope["providerId"] as? String,
      let executionMode = envelope["executionMode"] as? String,
      let terminalState = envelope["terminalState"] as? String
    else {
      return .unavailable("Job evidence did not match the selected Job")
    }

    let parameterObject = envelope["parameters"] as? [String: Any]
    let parameters = (parameterObject ?? [:]).keys.sorted().map { name in
      RuntimeJobParameterPresentation(
        name: name,
        value: displayValue(parameterObject?[name] ?? NSNull()))
    }
    let authority = envelope["authority"] as? [String: Any]
    let observation = envelope["observation"] as? [String: Any]
    let trace = decodeTraceEvidence(envelope)
    return .available(
      RuntimeJobEvidencePresentation(
        catalogDigest: catalogDigest,
        bindingRevision: envelope["bindingRevision"] as? Int,
        providerID: providerID,
        actualEffect: envelope["actualEffect"] as? String,
        executionMode: executionMode,
        terminalState: terminalState,
        startedAtUTC: envelope["startedAtUtc"] as? String,
        firstEvidenceStepAtUTC: envelope["firstEvidenceStepAtUtc"] as? String,
        finishedAtUTC: envelope["finishedAtUtc"] as? String,
        parameters: parameters,
        parametersWereReported: parameterObject != nil,
        actualStepKinds: envelope["actualStepKinds"] as? [String] ?? [],
        authorityKind: authority?["kind"] as? String,
        authorityReference: authority?["reference"] as? String,
        observedModel: observation?["model"] as? String,
        observedFirmware: observation?["firmware"] as? String,
        observedTransport: observation?["transport"] as? String,
        observedBindingRevision: observation?["bindingRevision"] as? Int,
        traceTags: trace.tags,
        traceParameters: trace.parameters,
        blockers: envelope["blockers"] as? [String] ?? []))
  }

  private static func decodeTraceEvidence(
    _ envelope: [String: Any]
  ) -> (tags: [String], parameters: [RuntimeTraceParameterPresentation]) {
    guard let before = envelope["traceProbeBefore"] as? [String: Any],
      let after = envelope["traceProbeAfter"] as? [String: Any],
      before["targetId"] as? String == after["targetId"] as? String,
      before["bindingRevision"] as? Int == after["bindingRevision"] as? Int,
      let tags = before["supportedTags"] as? [String],
      let beforeRows = before["parameters"] as? [[String: Any]],
      let afterRows = after["parameters"] as? [[String: Any]]
    else { return ([], []) }
    let beforeByName = Dictionary(
      uniqueKeysWithValues: beforeRows.compactMap { row -> (String, [String: Any])? in
        guard let name = row["name"] as? String else { return nil }
        return (name, row)
      })
    let afterByName = Dictionary(
      uniqueKeysWithValues: afterRows.compactMap { row -> (String, [String: Any])? in
        guard let name = row["name"] as? String else { return nil }
        return (name, row)
      })
    let expectedNames = TraceDebugParameterCatalog.definitions.map(\.name)
    guard Set(beforeByName.keys) == Set(expectedNames),
      Set(afterByName.keys) == Set(expectedNames)
    else { return ([], []) }
    let parameters = expectedNames.compactMap { name -> RuntimeTraceParameterPresentation? in
      guard let before = beforeByName[name], let after = afterByName[name],
        let beforeState = before["state"] as? String,
        let afterState = after["state"] as? String
      else { return nil }
      return RuntimeTraceParameterPresentation(
        name: name,
        beforeState: beforeState, beforeValue: before["value"] as? String,
        afterState: afterState, afterValue: after["value"] as? String)
    }
    guard parameters.count == expectedNames.count else { return ([], []) }
    return (tags, parameters)
  }

  private static func decodeArtifacts(
    jobID: String,
    operationReference: String,
    response: RuntimeHistoryTransportResult
  ) -> Section<[RuntimeArtifactPresentation]> {
    let values: [[String: Any]]
    switch response {
    case .failure(let reason): return .unavailable(reason)
    case .success(let data):
      switch resultArray(from: data, label: "Artifact metadata") {
      case .available(let value): values = value
      case .unavailable(let reason): return .unavailable(reason)
      }
    }

    let descriptor = RuntimeOperationCatalog.descriptor(reference: operationReference)
    var artifacts: [RuntimeArtifactPresentation] = []
    for value in values {
      guard
        value["jobId"] as? String == jobID,
        let artifactID = value["artifactId"] as? String,
        let name = value["name"] as? String,
        let mediaType = value["mediaType"] as? String,
        let byteCount = int64(value["byteCount"]),
        let sha256 = value["sha256"] as? String,
        let privacy = value["privacy"] as? String,
        let status = value["status"] as? String,
        let sourceOperation = value["sourceOperation"] as? String,
        let createdAtUTC = value["createdAtUtc"] as? String,
        let redactionApplied = value["redactionApplied"] as? Bool
      else {
        return .unavailable("Runtime returned incomplete Artifact metadata")
      }
      artifacts.append(
        RuntimeArtifactPresentation(
          id: artifactID,
          name: name,
          role: descriptor?.artifacts.first(where: { $0.name == name })?.role.rawValue,
          mediaType: mediaType,
          byteCount: byteCount,
          sha256: sha256,
          privacy: privacy,
          status: status,
          statusDetail: statusDetail(value["statusDetail"]),
          sourceOperation: sourceOperation,
          createdAtUTC: createdAtUTC,
          redactionApplied: redactionApplied))
    }
    return .available(artifacts.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
  }

  private static func resultObject(
    from data: Data,
    label: String
  ) -> Section<[String: Any]> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .unavailable("\(label) response was unreadable")
    }
    if let error = object["error"] as? [String: Any] {
      return .unavailable(daemonReason(error, label: label))
    }
    guard object["ok"] as? Bool == true,
      let result = object["result"] as? [String: Any]
    else { return .unavailable("\(label) response was incomplete") }
    return .available(result)
  }

  private static func resultArray(
    from data: Data,
    label: String
  ) -> Section<[[String: Any]]> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .unavailable("\(label) response was unreadable")
    }
    if let error = object["error"] as? [String: Any] {
      return .unavailable(daemonReason(error, label: label))
    }
    guard object["ok"] as? Bool == true,
      let result = object["result"] as? [[String: Any]]
    else { return .unavailable("\(label) response was incomplete") }
    return .available(result)
  }

  private static func daemonReason(_ error: [String: Any], label: String) -> String {
    let code = error["code"] as? String ?? "unknown"
    let message = error["message"] as? String ?? "no message"
    return "\(label) was refused: \(code) — \(message)"
  }

  private static func displayValue(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let value = value as? String { return value }
    if let value = value as? Bool { return value ? "true" : "false" }
    if let value = value as? NSNumber { return value.stringValue }
    if JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      return text
    }
    return String(describing: value)
  }

  private static func int64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return nil
  }

  private static func statusDetail(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return displayValue(value)
  }
}

private actor RuntimeJobDetailFixtureProvider: RuntimeJobDetailApplicationProviding {
  func loadJobDetail(
    jobID: String,
    operationReference: String
  ) async -> RuntimeJobDetailPresentation {
    let isFlash = operationReference == "flash.dayu200"
    let isInterruptedHistoryFixture = jobID == "job-fixture-0002"
    return RuntimeJobDetailPresentation(
      jobID: jobID,
      timelineAvailability: .available,
      timeline: isInterruptedHistoryFixture
        ? ["queued", "running", "interrupted"]
        : isFlash
          ? ["queued", "preflight", "running", "waitingForDevice"]
          : ["queued", "running", "succeeded"],
      evidenceAvailability: .available,
      evidence: RuntimeJobEvidencePresentation(
        catalogDigest: String(repeating: "a", count: 64),
        bindingRevision: 1,
        providerID: isFlash ? "rockchip" : "openharmony-hdc",
        actualEffect: isFlash ? "destructive" : "readOnly",
        executionMode: "execute",
        terminalState: isFlash ? "outcomeUnknown" : "succeeded",
        startedAtUTC: "2026-08-06T08:00:00Z",
        firstEvidenceStepAtUTC: "2026-08-06T08:00:01Z",
        finishedAtUTC: isFlash ? nil : "2026-08-06T08:00:02Z",
        parameters: [
          RuntimeJobParameterPresentation(name: "fixture", value: "presentation-only")
        ],
        parametersWereReported: true,
        actualStepKinds: isFlash ? ["flashPartition"] : ["readDeviceFacts"],
        authorityKind: isFlash ? "runtimeCapability" : "defaultReadOnlyPolicy",
        authorityReference: "fixture-read-only",
        observedModel: "DAYU200",
        observedFirmware: isFlash ? "OpenHarmony-7.0.0.36" : "OpenHarmony fixture",
        observedTransport: isFlash ? "usb" : "fixture",
        observedBindingRevision: isFlash ? 2 : 1,
        traceTags: [],
        traceParameters: [],
        blockers: isFlash ? ["outcomeUnknown"] : []),
      artifactAvailability: .available,
      artifacts: isFlash
        ? [
          RuntimeArtifactPresentation(
            id: "artifact-fixture-flash-log",
            name: "flash-report.json",
            role: "derived",
            mediaType: "application/json",
            byteCount: 128,
            sha256: String(repeating: "b", count: 64),
            privacy: "standard",
            status: "published",
            statusDetail: nil,
            sourceOperation: operationReference,
            createdAtUTC: "2026-08-06T08:00:03Z",
            redactionApplied: true)
        ]
        : [])
  }

  func exportArtifact(
    jobID _: String,
    artifact _: RuntimeArtifactPresentation,
    destinationURL: URL,
    allowSensitive _: Bool
  ) async -> RuntimeArtifactExportResult {
    do {
      try Data("ArkDeck UI fixture Artifact\n".utf8).write(
        to: destinationURL, options: .atomic)
      return .completed(destinationURL)
    } catch {
      return .failed("Fixture Artifact export failed: \(error)")
    }
  }
}

/// UI automation receives presentation values through the same facade. It has
/// no transport and cannot reach a daemon.
private actor RuntimeHistoryFixtureProvider: RuntimeHistoryApplicationProviding {
  private let launchArguments: [String]
  /// Same state file the HDC fixture reads, for the same reason: one launched
  /// instance has to be able to walk both the reachable and the unreachable
  /// history without a relaunch. Only the fixture provider reads it.
  private let stateFileURL: URL?

  init(arguments: [String]) {
    launchArguments = arguments
    if let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      stateFileURL = URL(filePath: arguments[index + 1])
    } else {
      stateFileURL = nil
    }
  }

  private func fixtureRequests(_ flag: String) -> Bool {
    if let stateFileURL, let text = try? String(contentsOf: stateFileURL, encoding: .utf8) {
      return text.contains(flag)
    }
    return launchArguments.contains(flag)
  }

  private var unreachable: Bool { fixtureRequests("--ui-test-runtime-history-unreachable") }

  /// A reachable Runtime that has run nothing yet. This is what a new install
  /// shows, and it is a different presentation from an unreadable history —
  /// the domain already keeps them apart, but nothing rendered the empty one.
  private var empty: Bool { fixtureRequests("--ui-test-runtime-history-empty") }
  private var flashRunning: Bool { fixtureRequests("--ui-test-runtime-flash-running") }
  private var flashResolvedRecovery: Bool {
    fixtureRequests("--ui-test-runtime-flash-resolved-recovery")
  }
  private var flashSucceeded: Bool { fixtureRequests("--ui-test-runtime-flash-succeeded") }

  func refreshHistory() async -> RuntimeHistoryPresentation {
    guard !unreachable else {
      return .unavailable("ArkDeck Runtime is not reachable: fixture")
    }
    guard !empty else {
      return RuntimeHistoryPresentation(availability: .available, jobs: [])
    }
    if flashRunning {
      return RuntimeHistoryPresentation(
        availability: .available,
        jobs: [
          RuntimeJobSummaryPresentation(
            id: "job-fixture-flash-running",
            operationReference: "flash.dayu200",
            targetID: "target-fixture-dayu200",
            state: "running",
            waitingForHuman: false,
            outcomeUnknown: false,
            outstandingResidueCount: 0,
            timeline: ["queued", "preflight", "running"],
            executionMode: "execute",
            sessionID: "session-job-fixture-flash-running",
            actualEffect: "destructive",
            createdAtUTC: "2026-08-06T08:00:00Z",
            startedAtUTC: "2026-08-06T08:00:01Z")
        ])
    }
    if flashResolvedRecovery {
      return RuntimeHistoryPresentation(
        availability: .available,
        jobs: [
          RuntimeJobSummaryPresentation(
            id: "job-fixture-flash-resolved-recovery",
            operationReference: "flash.dayu200",
            targetID: "target-fixture-dayu200",
            state: "waitingForRecovery",
            waitingForHuman: false,
            outcomeUnknown: true,
            outstandingResidueCount: 0,
            timeline: ["queued", "preflight", "running", "waitingForRecovery"],
            executionMode: "execute",
            sessionID: "session-job-fixture-flash-resolved-recovery",
            actualEffect: "destructive",
            createdAtUTC: "2026-08-06T08:00:00Z",
            startedAtUTC: "2026-08-06T08:00:01Z",
            supersededByRecoveryEpochID: "recovery-epoch-fixture")
        ])
    }
    if flashSucceeded {
      return RuntimeHistoryPresentation(
        availability: .available,
        jobs: [
          RuntimeJobSummaryPresentation(
            id: "job-fixture-flash-succeeded",
            operationReference: "flash.dayu200",
            targetID: "target-fixture-dayu200",
            state: "succeeded",
            waitingForHuman: false,
            outcomeUnknown: false,
            outstandingResidueCount: 0,
            timeline: ["queued", "preflight", "running", "waitingForDevice", "succeeded"],
            executionMode: "execute",
            sessionID: "session-job-fixture-flash-succeeded",
            actualEffect: "destructive",
            createdAtUTC: "2026-08-06T08:00:00Z",
            startedAtUTC: "2026-08-06T08:00:01Z",
            finishedAtUTC: "2026-08-06T08:03:00Z")
        ])
    }
    return RuntimeHistoryPresentation(
      availability: .available,
      jobs: [
        RuntimeJobSummaryPresentation(
          id: "job-fixture-0001",
          operationReference: "observe.device@1",
          targetID: "target-fixture-a",
          state: "succeeded",
          waitingForHuman: false,
          outcomeUnknown: false,
          outstandingResidueCount: 0,
          timeline: ["queued", "running", "succeeded"],
          executionMode: "execute",
          sessionID: "session-job-fixture-0001",
          actualEffect: "readOnly",
          createdAtUTC: "2026-08-06T07:00:00Z",
          startedAtUTC: "2026-08-06T07:00:01Z",
          finishedAtUTC: "2026-08-06T07:00:02Z"),
        RuntimeJobSummaryPresentation(
          id: "job-fixture-0002",
          operationReference: "flash.dayu200",
          targetID: "target-fixture-b",
          state: "interrupted",
          waitingForHuman: true,
          outcomeUnknown: true,
          outstandingResidueCount: 2,
          timeline: ["queued", "running", "interrupted"],
          executionMode: "execute",
          sessionID: "session-job-fixture-0002",
          actualEffect: "destructive",
          createdAtUTC: "2026-08-06T08:00:00Z",
          startedAtUTC: "2026-08-06T08:00:01Z",
          finishedAtUTC: "2026-08-06T08:02:00Z"),
      ])
  }
}
