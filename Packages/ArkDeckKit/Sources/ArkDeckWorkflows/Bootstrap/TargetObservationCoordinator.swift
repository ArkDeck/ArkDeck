import ArkDeckCore
import Foundation

/// A live USB relation independently observed by the Runtime. Neither the
/// connect key nor a hash of it can construct this proof.
package struct TargetUSBRelation: Equatable, Sendable {
  let serial: String
  let location: String
  let attachmentID: UInt64
  let vendorID: UInt16
  let productID: UInt16

  package static func registeredDAYU200() throws -> [Self] {
    try RockchipProductUSBProbe.systemIdentities().compactMap { identity in
      guard identity.isHDCNormal, let attachmentID = identity.registryEntryID else { return nil }
      return Self(
        serial: identity.serial, location: identity.topology, attachmentID: attachmentID,
        vendorID: identity.vendorID, productID: identity.productID)
    }
  }

  var isUsable: Bool {
    (1...1024).contains(serial.utf8.count) && serial.utf8.allSatisfy({ (33...126).contains($0) })
      && !serial.contains(":") && UInt64(location).map(String.init) == location && attachmentID != 0
      && vendorID == RockchipProbeEvidence.rockUSBVendorID
      && productID == RockchipHDCIntegrationProfile.dayu200NormalProductID
  }
}

package struct TargetObservationReference: Equatable, Sendable {
  package let candidate: String
  package let observationID: String
  package let generation: UInt64

  package init(candidate: String, observationID: String, generation: UInt64) {
    self.candidate = candidate
    self.observationID = observationID
    self.generation = generation
  }
}

package struct TargetObservationFailure: Error, Equatable, Sendable {
  package let code: String
  package let message: String
  package let reference: TargetObservationReference?

  package init(_ code: String, _ message: String, reference: TargetObservationReference? = nil) {
    self.code = code
    self.message = message
    self.reference = reference
  }
}

package struct TargetDeviceObservation: Equatable, Sendable {
  package let candidate: BootstrapCandidate
  package let observationID: String
  let firstGeneration: UInt64
  package let relation: TargetUSBRelation?

  package var continuity: String { relation == nil ? "generationScoped" : "relationProven" }
}

package struct TargetObservationSnapshot: Sendable {
  package let generation: UInt64
  package let observedAtUTC: String
  package let observations: [TargetDeviceObservation]
}

/// The target protocol owns its discovery relation separately from the frozen
/// 1.x presentation cache. No background refresh can turn a legacy display
/// read into a target adoption. Every target read uses typed HDC enumeration
/// bracketed by independent USB attachment observations.
public actor TargetObservationCoordinator {
  private struct Reading: Sendable {
    let candidates: [BootstrapCandidate]
    let before: [TargetUSBRelation]
    let after: [TargetUSBRelation]
  }

  private let observation: any BootstrapObservationPort
  private let targetStore: RuntimeTargetStore
  private let usbRelations: @Sendable () throws -> [TargetUSBRelation]
  private let nowUTC: @Sendable () -> String
  private var latest: TargetObservationSnapshot?
  private var lastGeneration: UInt64 = 0
  private var inFlight: (id: UUID, task: Task<Reading, Error>)?

  package init(
    observation: any BootstrapObservationPort,
    targetStore: RuntimeTargetStore,
    usbRelations: @escaping @Sendable () throws -> [TargetUSBRelation],
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.observation = observation
    self.targetStore = targetStore
    self.usbRelations = usbRelations
    self.nowUTC = nowUTC
  }

  package func snapshot(following reference: TargetObservationReference? = nil) async throws
    -> TargetObservationSnapshot
  {
    if let reference { _ = try current(reference, allowNewer: true) }
    let flight: (id: UUID, task: Task<Reading, Error>)
    if let inFlight {
      flight = inFlight
    } else {
      let observation = observation
      let usbRelations = usbRelations
      let task = Task {
        let before = try usbRelations()
        let candidates = try await observation.listCandidates()
        return Reading(candidates: candidates, before: before, after: try usbRelations())
      }
      flight = (UUID(), task)
      inFlight = flight
    }
    do {
      let reading = try await flight.task.value
      if inFlight?.id == flight.id {
        latest = try stamp(reading)
        targetStore.recordLiveHDCCandidates(reading.candidates)
        inFlight = nil
      }
      guard let latest else {
        throw TargetObservationFailure("recordUnreadable", "no completed observation snapshot")
      }
      if let reference { _ = try current(reference, allowNewer: true) }
      return latest
    } catch {
      if inFlight?.id == flight.id {
        inFlight = nil
        // A failed observation breaks proof of continuity. The next refresh
        // must mint new identities; it cannot silently bridge this gap.
        latest = nil
      }
      throw error
    }
  }

  package func adopt(_ reference: TargetObservationReference) async throws -> RuntimeTargetRecord {
    let initial = try current(reference, allowNewer: false)
    guard initial.relation != nil else {
      throw TargetObservationFailure(
        initial.candidate.state == "Unauthorized" ? "targetTrustPending" : "admissionDenied",
        "this observation has no independently proved physical relation", reference: reference)
    }
    _ = try await snapshot()
    let selected = try current(reference, allowNewer: false)
    guard selected.candidate.state == "Connected" else {
      throw TargetObservationFailure(
        selected.candidate.state == "Unauthorized" ? "targetTrustPending" : "admissionDenied",
        "the exact observed candidate is not authorized and connected", reference: reference)
    }
    guard let relation = selected.relation else {
      throw TargetObservationFailure(
        "admissionDenied", "the Runtime cannot prove this candidate's physical identity",
        reference: reference)
    }
    let toolVersion: String
    let readback: [String: String]
    let live: [TargetUSBRelation]
    do {
      toolVersion = try await observation.observeToolVersion()
      readback = try await observation.observeDeviceIdentity(connectKey: reference.candidate)
      live = try usbRelations().filter { $0.isUsable && $0.serial == reference.candidate }
    } catch {
      latest = nil
      throw error
    }
    // Actor reentrancy may have published a newer snapshot during either
    // typed read. The generation check and final independent USB read both
    // happen before the synchronous store call, with no intervening await.
    let final = try current(reference, allowNewer: false)
    guard final.relation == relation, live == [relation], readback["serial"] == relation.serial
    else {
      throw TargetObservationFailure(
        "factsDrifted", "physical identity changed during adoption readback", reference: reference)
    }
    return try targetStore.adopt(
      stableIdentitySHA256: DeviceBootstrapMachine.stableIdentitySHA256(serial: relation.serial),
      connectKey: reference.candidate, toolVersion: toolVersion, nowUTC: nowUTC()
    ).record
  }

  private func current(_ reference: TargetObservationReference, allowNewer: Bool) throws
    -> TargetDeviceObservation
  {
    guard let latest, reference.generation > 0,
      allowNewer
        ? latest.generation >= reference.generation : latest.generation == reference.generation,
      let row = latest.observations.first(where: {
        $0.observationID == reference.observationID
          && $0.candidate.connectKey == reference.candidate
      }), row.firstGeneration <= reference.generation,
      !allowNewer || row.relation != nil || latest.generation == reference.generation
    else {
      throw TargetObservationFailure(
        "resourceConflict", "the exact observation no longer belongs to the current snapshot",
        reference: reference)
    }
    return row
  }

  private func stamp(_ reading: Reading) throws -> TargetObservationSnapshot {
    guard reading.candidates.count <= 1000,
      reading.candidates.allSatisfy({ (1...1024).contains($0.connectKey.utf8.count) })
    else {
      throw TargetObservationFailure("operationUnavailable", "device snapshot exceeds its bounds")
    }
    let next = lastGeneration.addingReportingOverflow(1)
    guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
      throw TargetObservationFailure("recordUnreadable", "observation generation exhausted")
    }
    let counts = Dictionary(grouping: reading.candidates, by: \.connectKey)
    let ordered = reading.candidates.sorted {
      if $0.connectKey != $1.connectKey {
        return $0.connectKey.utf8.lexicographicallyPrecedes($1.connectKey.utf8)
      }
      return $0.state.utf8.lexicographicallyPrecedes($1.state.utf8)
    }
    let rows = ordered.map { candidate in
      let before = reading.before.filter { $0.isUsable && $0.serial == candidate.connectKey }
      let after = reading.after.filter { $0.isUsable && $0.serial == candidate.connectKey }
      let relation =
        counts[candidate.connectKey]?.count == 1 && before.count == 1 && before == after
        ? before.first : nil
      let previous = latest?.observations.first {
        relation != nil && $0.relation == relation
          && $0.candidate.connectKey == candidate.connectKey
      }
      return TargetDeviceObservation(
        candidate: candidate,
        observationID: previous?.observationID ?? "obs-\(UUID().uuidString.lowercased())",
        firstGeneration: previous?.firstGeneration ?? next.partialValue, relation: relation)
    }
    // Unchanged, independently verified facts do not create a new fact
    // generation. A state transition does, while preserving a proved ID.
    let generation = latest?.observations == rows ? latest!.generation : next.partialValue
    lastGeneration = generation
    return TargetObservationSnapshot(
      generation: generation, observedAtUTC: nowUTC(), observations: rows)
  }
}
