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

  public init(
    id: String, operationReference: String, targetID: String, state: String,
    waitingForHuman: Bool, outcomeUnknown: Bool, outstandingResidueCount: Int,
    timeline: [String]
  ) {
    self.id = id
    self.operationReference = operationReference
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.outstandingResidueCount = outstandingResidueCount
    self.timeline = timeline
  }

  /// An unknown outcome is never folded into a terminal state: it is the one
  /// condition a reader must not mistake for "finished".
  public var needsAttention: Bool { outcomeUnknown || waitingForHuman }
}

public struct RuntimeHistoryPresentation: Sendable, Equatable {
  public let availability: RuntimeHistoryAvailability
  public let jobs: [RuntimeJobSummaryPresentation]

  public init(availability: RuntimeHistoryAvailability, jobs: [RuntimeJobSummaryPresentation]) {
    self.availability = availability
    self.jobs = jobs
  }

  public static let loading = RuntimeHistoryPresentation(
    availability: .unavailable(reason: "Runtime history is loading"), jobs: [])

  static func unavailable(_ reason: String) -> RuntimeHistoryPresentation {
    RuntimeHistoryPresentation(availability: .unavailable(reason: reason), jobs: [])
  }
}

/// Closed App-facing surface. It exposes one read and nothing else: there is
/// no submit, run, cancel, reconcile, adopt or import method to call.
public protocol RuntimeHistoryApplicationProviding: Sendable {
  func refreshHistory() async -> RuntimeHistoryPresentation
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

/// Production transport. The Unix socket is unreachable from an App Sandbox
/// container, so this speaks the daemon's Mach service instead; when launchd
/// is not vending it the connection simply never answers and this reports an
/// accurate reason rather than pretending the history is empty.
private actor RuntimeHistoryXPCProvider: RuntimeHistoryApplicationProviding {
  func refreshHistory() async -> RuntimeHistoryPresentation {
    let frame: Data
    do {
      frame = try JSONSerialization.data(
        withJSONObject: ["v": 1, "id": UUID().uuidString, "method": "job.list"])
    } catch {
      return .unavailable("Could not compose a Runtime history request")
    }

    let response = await Self.send(frame)
    switch response {
    case .failure(let reason):
      return .unavailable(reason)
    case .success(let data):
      return RuntimeHistoryResponseDecoding.presentation(from: data)
    }
  }

  private enum TransportResult {
    case success(Data)
    case failure(String)
  }

  private static func send(_ frame: Data) async -> TransportResult {
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
      @Sendable func finish(_ result: TransportResult) {
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
    var jobs: [RuntimeJobSummaryPresentation] = []
    for entry in result {
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
          timeline: entry["timeline"] as? [String] ?? []))
    }
    return RuntimeHistoryPresentation(availability: .available, jobs: jobs)
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
      stateFileURL = URL(fileURLWithPath: arguments[index + 1])
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
            operationReference: "flash.dayu200@1",
            targetID: "target-fixture-dayu200",
            state: "running",
            waitingForHuman: false,
            outcomeUnknown: false,
            outstandingResidueCount: 0,
            timeline: ["queued", "preflight", "running"])
        ])
    }
    if flashSucceeded {
      return RuntimeHistoryPresentation(
        availability: .available,
        jobs: [
          RuntimeJobSummaryPresentation(
            id: "job-fixture-flash-succeeded",
            operationReference: "flash.dayu200@1",
            targetID: "target-fixture-dayu200",
            state: "succeeded",
            waitingForHuman: false,
            outcomeUnknown: false,
            outstandingResidueCount: 0,
            timeline: ["queued", "preflight", "running", "waitingForDevice", "succeeded"])
        ])
    }
    return RuntimeHistoryPresentation(
      availability: .available,
      jobs: [
        RuntimeJobSummaryPresentation(
          id: "job-fixture-0001",
          operationReference: "observe.devices@1",
          targetID: "target-fixture-a",
          state: "succeeded",
          waitingForHuman: false,
          outcomeUnknown: false,
          outstandingResidueCount: 0,
          timeline: ["queued", "running", "succeeded"]),
        RuntimeJobSummaryPresentation(
          id: "job-fixture-0002",
          operationReference: "flash.dayu200@1",
          targetID: "target-fixture-b",
          state: "interrupted",
          waitingForHuman: true,
          outcomeUnknown: true,
          outstandingResidueCount: 2,
          timeline: ["queued", "running", "interrupted"]),
      ])
  }
}

/// NSXPCConnection is thread-safe by contract but predates `Sendable`.
private final class XPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}
