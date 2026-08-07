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

/// One HDC device candidate with its raw reported state, joined against the
/// durable target store when it is already adopted. `state` is the tool's own
/// vocabulary (`Connected` / `Unauthorized` / `Offline`), shown rather than
/// reinterpreted; the two derived flags mirror `BootstrapCandidate` exactly.
public struct DeviceCandidatePresentation: Sendable, Equatable, Identifiable {
  public let connectKey: String
  public let state: String
  public let adoptedTargetID: String?
  public let bindingRevision: Int?

  public init(
    connectKey: String, state: String, adoptedTargetID: String?, bindingRevision: Int?
  ) {
    self.connectKey = connectKey
    self.state = state
    self.adoptedTargetID = adoptedTargetID
    self.bindingRevision = bindingRevision
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
    switch await DeviceListXPCReadTransport.request(method: "device.candidates") {
    case .failure(.transport(let reason)):
      return DeviceListPresentation(
        availability: .unavailable(reason: reason), candidates: [])
    case .success(let data):
      return DeviceCandidatesResponseDecoding.presentation(data)
    }
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
          bindingRevision: 3),
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
  static func request(method: String) async -> Result<Data, DeviceListXPCReadFailure> {
    let frame: Data
    do {
      frame = try JSONSerialization.data(
        withJSONObject: ["v": 1, "id": UUID().uuidString, "method": method])
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
