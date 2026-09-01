import ArkDeckAgentClient
import ArkDeckCore
import Foundation

extension RuntimeCLI {
  /// Unary polling is intentionally not an event stream. Every read asks the
  /// Runtime to prove the original lifecycle again, even when the requested
  /// state already matched the caller's earlier discovery snapshot.
  static func emitDeviceWait(_ arguments: [String], session original: CLIRuntimeSession) throws {
    let options = try CLIOptions(arguments)
    guard let candidate = options.value("--candidate"),
      let observationID = options.value("--observation"),
      let generation = options.value("--observation-generation"),
      let initialGeneration = Int64(generation), initialGeneration > 0,
      let state = options.value("--state"),
      let providerState = [
        "connected": "Connected", "unauthorized": "Unauthorized", "offline": "Offline",
      ][state],
      let timeout = CLIDuration.parse(
        options.value("--timeout") ?? "30s", maximumMilliseconds: 86_400_000)
    else {
      throw original.fail(
        .invalidOption, "device wait requires an exact observation, state and bounded timeout")
    }
    let reference: [String: JSONValue] = [
      "candidate": .string(candidate), "observationId": .string(observationID),
      "observationGeneration": .string(generation),
    ]
    let deadline = try AgentClientWaitDeadline(milliseconds: timeout.milliseconds)
    var session = original
    session.client = session.client.bounded(by: deadline)
    var lastGeneration: Int64?
    do {
      try session.negotiate(requiredMajor: 2, forMethod: "device.observations")
      var interval = 100
      while true {
        let snapshot = try session.request("device.observations", ["following": .object(reference)])
        guard case .object(let fields) = snapshot,
          Set(fields.keys) == [
            "schemaVersion", "snapshotGeneration", "observedAtUtc", "health", "observations",
          ],
          fields["schemaVersion"] == .string("arkdeck.device-observations/1"),
          fields["health"] == .string("current"),
          case .string(let observedAt)? = fields["observedAtUtc"], !observedAt.isEmpty,
          case .string(let finalGeneration)? = fields["snapshotGeneration"],
          let number = Int64(finalGeneration), String(number) == finalGeneration,
          number >= (lastGeneration ?? initialGeneration),
          case .array(let rows)? = fields["observations"], rows.count <= 1000
        else {
          throw session.fail(
            .protocolMalformed, "the Runtime returned an invalid device observation snapshot")
        }
        let matches = rows.compactMap { value -> [String: JSONValue]? in
          guard case .object(let row) = value,
            row["candidateKey"] == .string(candidate),
            row["observationId"] == .string(observationID)
          else { return nil }
          return row
        }
        guard matches.count == 1, let row = matches.first,
          Set(row.keys) == [
            "candidateKey", "observationId", "authorizationState", "observationContinuity",
            "adoptedTargetId", "bindingRevision", "displayName", "displayNameGeneration",
          ],
          row["observationContinuity"] == .string("relationProven"),
          row["displayNameGeneration"] == .string(finalGeneration)
        else {
          throw session.fail(
            .resourceConflict,
            "the Runtime did not prove the original device observation lifecycle",
            details: reference)
        }
        guard case .string(let actualState)? = row["authorizationState"],
          ["Connected", "Unauthorized", "Offline"].contains(actualState)
        else {
          throw session.fail(
            .protocolMalformed, "the observation has no supported authorization state")
        }
        switch (row["adoptedTargetId"], row["bindingRevision"]) {
        case (.some(.null), .some(.null)): break
        case (.some(.string(let target)), .some(.integer(let revision)))
        where !target.isEmpty && revision > 0: break
        default:
          throw session.fail(
            .protocolMalformed, "the observation has an invalid adopted-target link")
        }
        switch row["displayName"] {
        case .some(.null): break
        case .some(.string(let name))
        where name == name.precomposedStringWithCanonicalMapping
          && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
          && (1...256).contains(name.utf8.count)
          && name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }):
          break
        default:
          throw session.fail(
            .protocolMalformed, "the observation has an invalid candidate display name")
        }
        lastGeneration = number
        try deadline.check()
        if actualState == providerState {
          session.emit(
            .object([
              "schemaVersion": .string("arkdeck.device-wait/1"),
              "snapshotGeneration": .string(finalGeneration), "observedAtUtc": .string(observedAt),
              "state": .string(state), "observation": .object(row),
            ]))
          return
        }
        Thread.sleep(forTimeInterval: Double(min(interval, deadline.remainingMilliseconds)) / 1000)
        interval = min(interval * 2, 2000)
        try deadline.check()
      }
    } catch AgentClientError.deadlineExceeded {
      throw deviceWaitTimeout(
        session, reference: reference, state: state, lastGeneration: lastGeneration)
    } catch let error as CLIRegistryError where error.code == .clientTimeout {
      throw deviceWaitTimeout(
        session, reference: reference, state: state, lastGeneration: lastGeneration)
    }
  }

  private static func deviceWaitTimeout(
    _ session: CLIRuntimeSession, reference: [String: JSONValue], state: String,
    lastGeneration: Int64?
  ) -> CLIRegistryError {
    var details = reference
    details["requestedState"] = .string(state)
    if let lastGeneration { details["lastObservedGeneration"] = .string(String(lastGeneration)) }
    details["newDispatchCount"] = .integer(0)
    return session.fail(
      .clientTimeout,
      "stopped waiting for the exact device observation; no adoption or cancellation was requested",
      details: details)
  }
}
