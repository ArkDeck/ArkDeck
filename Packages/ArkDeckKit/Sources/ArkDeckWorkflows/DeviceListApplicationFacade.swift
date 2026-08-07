// App-facing device discovery read.
//
// One question, answered honestly: which device candidates does HDC see
// right now, with which raw connection state, and which of them are already
// adopted targets. The projection is fed by the daemon's `device.candidates`
// method, which enumerates via the bootstrap's candidate read and never
// touches `advance` — so nothing reachable from this facade can create,
// select or change a binding. Adoption stays a CLI act (`target.adopt` is
// refused by the App transport's allowlist).

import ArkDeckCore
import Foundation
import os

/// Device facts observed by the most recent succeeded `observe.device@1` job
/// for an adopted target — model, firmware and transport as the device
/// reported them, plus when that confirmation happened. This is historical
/// evidence, not live state: it names the device, it does not certify it.
public struct DeviceObservedFactsPresentation: Sendable, Equatable {
  public let model: String?
  public let firmware: String?
  public let transport: String?
  public let confirmedAtUTC: String?

  public init(model: String?, firmware: String?, transport: String?, confirmedAtUTC: String?) {
    self.model = model
    self.firmware = firmware
    self.transport = transport
    self.confirmedAtUTC = confirmedAtUTC
  }
}

/// One HDC device candidate with its raw reported state, joined against the
/// durable target store when it is already adopted. `state` is the tool's own
/// vocabulary (`Connected` / `Unauthorized` / `Offline`), shown rather than
/// reinterpreted; the two derived flags mirror `BootstrapCandidate` exactly.
/// `observedFacts` is nil when no succeeded observation evidence exists for
/// the adopted target — absence renders as absence, never as a placeholder.
public struct DeviceCandidatePresentation: Sendable, Equatable, Identifiable {
  public let connectKey: String
  public let state: String
  public let adoptedTargetID: String?
  public let bindingRevision: Int?
  public let observedFacts: DeviceObservedFactsPresentation?

  public init(
    connectKey: String, state: String, adoptedTargetID: String?, bindingRevision: Int?,
    observedFacts: DeviceObservedFactsPresentation? = nil
  ) {
    self.connectKey = connectKey
    self.state = state
    self.adoptedTargetID = adoptedTargetID
    self.bindingRevision = bindingRevision
    self.observedFacts = observedFacts
  }

  public var id: String { connectKey }
  public var isAuthorized: Bool { state == "Connected" }
  public var needsPhysicalTrust: Bool { state == "Unauthorized" || state == "Offline" }
  public var isAdopted: Bool { adoptedTargetID != nil }
}

public struct DeviceListPresentation: Sendable, Equatable {
  public enum Availability: Sendable, Equatable {
    case checking
    case available
    case unavailable(reason: String)
  }

  public let availability: Availability
  public let candidates: [DeviceCandidatePresentation]

  public init(availability: Availability, candidates: [DeviceCandidatePresentation]) {
    self.availability = availability
    self.candidates = candidates
  }

  public static let loading = DeviceListPresentation(availability: .checking, candidates: [])
}

public protocol DeviceListApplicationProviding: Sendable {
  func refreshCandidates() async -> DeviceListPresentation
}

public enum DeviceListApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any DeviceListApplicationProviding {
    if arguments.contains("--ui-test-devices") {
      return DeviceListFixtureApplicationProvider()
    }
    return DeviceListProductionApplicationProvider()
  }
}

private actor DeviceListProductionApplicationProvider: DeviceListApplicationProviding {
  func refreshCandidates() async -> DeviceListPresentation {
    let base: DeviceListPresentation
    switch await DeviceListXPCReadTransport.request(method: "device.candidates") {
    case .failure(.transport(let reason)):
      return DeviceListPresentation(
        availability: .unavailable(reason: reason), candidates: [])
    case .success(let data):
      base = DeviceCandidatesResponseDecoding.presentation(data)
    }
    return await joinObservedFacts(into: base)
  }

  /// Decorates adopted candidates with the model / firmware / transport their
  /// most recent succeeded `observe.device@1` job recorded, via the already
  /// allowlisted `job.list` + `job.evidence` reads. The candidate list is the
  /// primary fact and stays fail-loud; this decoration is historical evidence
  /// that may legitimately not exist yet (a freshly adopted device has run no
  /// observation), so a missing or unreadable evidence record leaves the
  /// candidate undecorated instead of failing the list.
  private func joinObservedFacts(
    into base: DeviceListPresentation
  ) async -> DeviceListPresentation {
    guard case .available = base.availability else { return base }
    let adoptedIDs = Set(base.candidates.compactMap(\.adoptedTargetID))
    guard !adoptedIDs.isEmpty else { return base }
    guard
      case .success(let jobData) = await DeviceListXPCReadTransport.request(method: "job.list")
    else { return base }
    let latest = DeviceCandidatesResponseDecoding.latestSucceededObservationJobIDs(
      jobData, adoptedTargetIDs: adoptedIDs)
    var facts: [String: DeviceObservedFactsPresentation] = [:]
    for (targetID, jobID) in latest {
      guard
        case .success(let evidenceData) = await DeviceListXPCReadTransport.request(
          method: "job.evidence", params: ["jobId": .string(jobID)]),
        let observed = DeviceCandidatesResponseDecoding.observedFacts(
          evidenceData, targetID: targetID)
      else { continue }
      facts[targetID] = observed
    }
    return DeviceCandidatesResponseDecoding.decorated(base, observedFactsByTargetID: facts)
  }
}

/// Incomplete facts are a reported failure, never a silently empty list: an
/// empty device list and an unreadable one must stay distinguishable.
enum DeviceCandidatesResponseDecoding {
  static func presentation(_ data: Data) -> DeviceListPresentation {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return DeviceListPresentation(
        availability: .unavailable(reason: "Runtime returned an unreadable response"),
        candidates: [])
    }
    if let error = object["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "Runtime rejected the request"
      return DeviceListPresentation(
        availability: .unavailable(reason: message), candidates: [])
    }
    guard let rows = object["result"] as? [[String: Any]] else {
      return DeviceListPresentation(
        availability: .unavailable(reason: "Runtime response carries no candidate list"),
        candidates: [])
    }
    var candidates: [DeviceCandidatePresentation] = []
    for row in rows {
      guard
        let connectKey = row["connectKey"] as? String, !connectKey.isEmpty,
        let state = row["state"] as? String, !state.isEmpty
      else {
        return DeviceListPresentation(
          availability: .unavailable(reason: "Runtime response carries an incomplete candidate"),
          candidates: [])
      }
      candidates.append(
        DeviceCandidatePresentation(
          connectKey: connectKey,
          state: state,
          adoptedTargetID: row["adoptedTargetId"] as? String,
          bindingRevision: (row["bindingRevision"] as? NSNumber)?.intValue))
    }
    return DeviceListPresentation(availability: .available, candidates: candidates)
  }

  /// The newest succeeded `observe.device@1` job per adopted target, chosen
  /// by `finishedAtUtc` (ISO-8601 UTC strings order lexicographically). A
  /// malformed job list yields no decoration, never a failure: the candidate
  /// list already rendered, and this join is evidence lookup on top of it.
  static func latestSucceededObservationJobIDs(
    _ data: Data, adoptedTargetIDs: Set<String>
  ) -> [String: String] {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["ok"] as? Bool == true,
      let rows = object["result"] as? [[String: Any]]
    else { return [:] }
    var newest: [String: (jobID: String, finishedAtUTC: String)] = [:]
    for row in rows {
      guard
        let jobID = row["jobId"] as? String,
        let operation = row["operation"] as? String, operation == "observe.device@1",
        let state = row["state"] as? String, state == "succeeded",
        let targetID = row["targetId"] as? String, adoptedTargetIDs.contains(targetID)
      else { continue }
      let finished = row["finishedAtUtc"] as? String ?? ""
      if let current = newest[targetID], current.finishedAtUTC >= finished { continue }
      newest[targetID] = (jobID, finished)
    }
    return newest.mapValues(\.jobID)
  }

  /// Reads the observation block out of a `job.evidence` envelope, accepting
  /// it only when the evidence names the same target it is being joined to —
  /// facts observed on one device must never decorate another.
  static func observedFacts(
    _ data: Data, targetID: String
  ) -> DeviceObservedFactsPresentation? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["ok"] as? Bool == true,
      let envelope = object["result"] as? [String: Any],
      let observation = envelope["observation"] as? [String: Any],
      observation["targetId"] as? String == targetID
    else { return nil }
    let facts = DeviceObservedFactsPresentation(
      model: observation["model"] as? String,
      firmware: observation["firmware"] as? String,
      transport: observation["transport"] as? String,
      confirmedAtUTC: observation["confirmedAtUtc"] as? String)
    let hasAnyFact =
      facts.model != nil || facts.firmware != nil || facts.transport != nil
    return hasAnyFact ? facts : nil
  }

  static func decorated(
    _ base: DeviceListPresentation,
    observedFactsByTargetID: [String: DeviceObservedFactsPresentation]
  ) -> DeviceListPresentation {
    guard !observedFactsByTargetID.isEmpty else { return base }
    return DeviceListPresentation(
      availability: base.availability,
      candidates: base.candidates.map { candidate in
        guard let targetID = candidate.adoptedTargetID,
          let facts = observedFactsByTargetID[targetID]
        else { return candidate }
        return DeviceCandidatePresentation(
          connectKey: candidate.connectKey,
          state: candidate.state,
          adoptedTargetID: candidate.adoptedTargetID,
          bindingRevision: candidate.bindingRevision,
          observedFacts: facts)
      })
  }
}

/// Presentation values only: one adopted ready device and one candidate that
/// still needs the on-device trust prompt, so UI automation can walk both
/// sidebar states and the authorization detail without any device.
private actor DeviceListFixtureApplicationProvider: DeviceListApplicationProviding {
  func refreshCandidates() async -> DeviceListPresentation {
    DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "150100469346864",
          state: "Connected",
          adoptedTargetID: "target-fixture-dayu200",
          bindingRevision: 3,
          observedFacts: DeviceObservedFactsPresentation(
            model: "DAYU200",
            firmware: "OpenHarmony 5.0.0.71",
            transport: "USB",
            confirmedAtUTC: "2026-08-07T00:00:00Z")),
        DeviceCandidatePresentation(
          connectKey: "7f2c091a445e21",
          state: "Unauthorized",
          adoptedTargetID: nil,
          bindingRevision: nil),
      ])
  }
}

enum DeviceListXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)
}

private enum DeviceListXPCReadTransport {
  static func request(
    method: String, params: [String: JSONValue]? = nil
  ) async -> Result<Data, DeviceListXPCReadFailure> {
    let frame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params)
    } catch {
      return .failure(.transport("Could not compose a Runtime request"))
    }
    return await withCheckedContinuation { continuation in
      let box = DeviceListXPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: Result<Data, DeviceListXPCReadFailure>) {
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
              .transport("ArkDeck Runtime is not reachable: \(error.localizedDescription)")))
        } as? ArkDeckAgentXPCProtocol
      guard let proxy else {
        finish(.failure(.transport("ArkDeck Runtime is not reachable")))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure(.transport("Runtime transport refused this request: \(refusal)")))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure(.transport("Runtime returned neither a response nor a reason")))
        }
      }
    }
  }
}

/// NSXPCConnection is thread-safe by contract but predates `Sendable`.
private final class DeviceListXPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}
