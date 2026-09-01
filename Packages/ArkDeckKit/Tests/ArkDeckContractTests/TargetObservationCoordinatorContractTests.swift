import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class TargetObservationCoordinatorContractTests: XCTestCase {
  final class Port: BootstrapObservationPort, @unchecked Sendable {
    private let lock = NSLock()
    private var state = "Connected"
    private var attachments: [TargetUSBRelation] = [Port.relation()]
    private var readFailure = false
    private var identityAction: (@Sendable () -> Void)?
    private var nextListAction: (@Sendable () -> Void)?
    private var duplicate = false

    static func relation(id: UInt64 = 17, location: String = "100") -> TargetUSBRelation {
      TargetUSBRelation(
        serial: "150100424a544e4600", location: location, attachmentID: id,
        vendorID: RockchipProbeEvidence.rockUSBVendorID,
        productID: RockchipHDCIntegrationProfile.dayu200NormalProductID)
    }
    func setState(_ value: String) { lock.withLock { state = value } }
    func setRelations(_ value: [TargetUSBRelation]) { lock.withLock { attachments = value } }
    func setReadFailure(_ value: Bool) { lock.withLock { readFailure = value } }
    func setDuplicate() { lock.withLock { duplicate = true } }
    func onIdentity(_ action: @escaping @Sendable () -> Void) {
      lock.withLock { identityAction = action }
    }
    func onNextList(_ action: @escaping @Sendable () -> Void) {
      lock.withLock { nextListAction = action }
    }
    func relations() throws -> [TargetUSBRelation] {
      try lock.withLock {
        if readFailure { throw BootstrapError.observationFailed("fixture read failure") }
        return attachments
      }
    }
    func listCandidates() async throws -> [BootstrapCandidate] {
      let action = lock.withLock {
        let action = nextListAction
        nextListAction = nil
        return action
      }
      action?()
      return lock.withLock {
        let row = BootstrapCandidate(connectKey: "150100424a544e4600", state: state)
        return duplicate ? [row, row] : [row]
      }
    }
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      let action = lock.withLock { identityAction }
      action?()
      return ["serial": connectKey]
    }
  }

  private var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "target-observation-\(UUID())")
  }
  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func stack(_ port: Port) throws -> (TargetObservationCoordinator, RuntimeTargetStore) {
    let store = try RuntimeTargetStore(directoryURL: directory)
    return (
      TargetObservationCoordinator(
        observation: port, targetStore: store, usbRelations: { try port.relations() },
        nowUTC: { "2026-08-31T12:00:00Z" }), store
    )
  }
  private func reference(_ snapshot: TargetObservationSnapshot) throws -> TargetObservationReference
  {
    let row = try XCTUnwrap(snapshot.observations.first)
    return TargetObservationReference(
      candidate: row.candidate.connectKey, observationID: row.observationID,
      generation: snapshot.generation)
  }

  func testOnlyExactIndependentlyProvedObservationCanCreateATarget() async throws {
    let (owner, store) = try stack(Port())
    let snapshot = try await owner.snapshot()
    XCTAssertEqual(try store.list().count, 0, "discovery must never adopt")
    XCTAssertEqual(snapshot.observations.first?.continuity, "relationProven")
    let ref = try reference(snapshot)
    let adopted = try await owner.adopt(ref)
    let repeated = try await owner.adopt(ref)
    XCTAssertEqual(adopted, repeated)
    XCTAssertEqual(try store.list().count, 1)
    XCTAssertEqual(adopted.bindingRevision, 1)
  }

  func testStateChangesAdvanceFactsButKeepAProvedAttachmentIdentity() async throws {
    let port = Port()
    port.setState("Unauthorized")
    let (owner, store) = try stack(port)
    let initial = try await owner.snapshot()
    let ref = try reference(initial)
    do {
      _ = try await owner.adopt(ref)
      XCTFail("trust is required")
    } catch let error as TargetObservationFailure {
      XCTAssertEqual(error.code, "targetTrustPending")
    }
    port.setState("Connected")
    let connected = try await owner.snapshot(following: ref)
    XCTAssertEqual(connected.observations.first?.observationID, ref.observationID)
    XCTAssertGreaterThan(connected.generation, ref.generation)
    do {
      _ = try await owner.adopt(ref)
      XCTFail("old generation must be refused")
    } catch let error as TargetObservationFailure { XCTAssertEqual(error.code, "resourceConflict") }
    XCTAssertEqual(try store.list().count, 0)
    _ = try await owner.adopt(reference(connected))
    XCTAssertEqual(try store.list().count, 1)
  }

  func testAnIdenticalSerialAtTheSamePortAfterReconnectIsANewObservation() async throws {
    let port = Port()
    let (owner, store) = try stack(port)
    let initial = try await owner.snapshot()
    let ref = try reference(initial)
    port.setRelations([Port.relation(id: 18)])
    do {
      _ = try await owner.snapshot(following: ref)
      XCTFail("must not follow a new attachment")
    } catch let error as TargetObservationFailure { XCTAssertEqual(error.code, "resourceConflict") }
    let fresh = try await owner.snapshot()
    XCTAssertNotEqual(fresh.observations.first?.observationID, ref.observationID)
    do {
      _ = try await owner.adopt(ref)
      XCTFail("must not adopt a reused key")
    } catch let error as TargetObservationFailure { XCTAssertEqual(error.code, "resourceConflict") }
    XCTAssertEqual(try store.list().count, 0)
  }

  func testUnprovedAndDuplicateCandidatesNeverCreateBindings() async throws {
    for duplicate in [false, true] {
      let port = Port()
      if duplicate { port.setDuplicate() } else { port.setRelations([]) }
      let (owner, store) = try stack(port)
      let snapshot = try await owner.snapshot()
      XCTAssertTrue(snapshot.observations.allSatisfy { $0.continuity == "generationScoped" })
      do {
        _ = try await owner.adopt(reference(snapshot))
        XCTFail("identity cannot be inferred")
      } catch let error as TargetObservationFailure {
        XCTAssertEqual(error.code, "admissionDenied")
      }
      XCTAssertEqual(try store.list().count, 0)
    }
  }

  func testReplacementDuringFinalReadbackFailsBeforeTheStoreWrite() async throws {
    let port = Port()
    let (owner, store) = try stack(port)
    let snapshot = try await owner.snapshot()
    port.onIdentity { port.setRelations([Port.relation(id: 19)]) }
    do {
      _ = try await owner.adopt(reference(snapshot))
      XCTFail("in-flight drift must be refused")
    } catch let error as TargetObservationFailure { XCTAssertEqual(error.code, "factsDrifted") }
    XCTAssertEqual(try store.list().count, 0)
  }

  func testObservationFailureBreaksContinuityWithoutReusingAGeneration() async throws {
    let port = Port()
    let (owner, _) = try stack(port)
    let initial = try await owner.snapshot()
    port.setReadFailure(true)
    do {
      _ = try await owner.snapshot()
      XCTFail("fixture read must fail")
    } catch {}
    port.setReadFailure(false)
    let recovered = try await owner.snapshot()
    XCTAssertGreaterThan(recovered.generation, initial.generation)
    XCTAssertNotEqual(
      recovered.observations.first?.observationID, initial.observations.first?.observationID)
  }

  func testFailedFinalReadbackInvalidatesTheOldObservation() async throws {
    let port = Port()
    let (owner, store) = try stack(port)
    let initial = try await owner.snapshot()
    port.onIdentity { port.setReadFailure(true) }
    do {
      _ = try await owner.adopt(reference(initial))
      XCTFail("readback must fail")
    } catch {}
    port.setReadFailure(false)
    let recovered = try await owner.snapshot()
    XCTAssertNotEqual(
      recovered.observations.first?.observationID, initial.observations.first?.observationID)
    XCTAssertGreaterThan(recovered.generation, initial.generation)
    XCTAssertEqual(try store.list().count, 0)
  }

  func testCandidateDisplayNameUsesObservationGenerationCASAndExpiresOnFactDrift() async throws {
    let port = Port()
    let (owner, store) = try stack(port)
    let initial = try await owner.snapshot()
    let initialReference = try reference(initial)
    XCTAssertEqual(initial.displayNames[initialReference.observationID]?.name, nil)
    XCTAssertEqual(
      initial.displayNames[initialReference.observationID]?.generation,
      initial.generation)

    let named = try await owner.setDisplayName(initialReference, name: "Bench device")
    XCTAssertEqual(named.name, "Bench device")
    XCTAssertEqual(named.generation, initial.generation + 1)
    let namedReference = TargetObservationReference(
      candidate: initialReference.candidate,
      observationID: initialReference.observationID,
      generation: named.generation)
    let current = try await owner.snapshot(following: initialReference)
    XCTAssertEqual(current.generation, named.generation)
    XCTAssertEqual(current.displayNames[initialReference.observationID]?.name, "Bench device")
    do {
      _ = try await owner.clearDisplayName(initialReference)
      XCTFail("stale display-name generation must be refused")
    } catch let error as TargetObservationFailure {
      XCTAssertEqual(error.code, "resourceConflict")
    }

    port.setState("Unauthorized")
    let changed = try await owner.snapshot(following: namedReference)
    XCTAssertGreaterThan(changed.generation, named.generation)
    XCTAssertNil(changed.displayNames[initialReference.observationID]?.name)
    let persisted = try store.candidateDisplayNames(references: [
      .init(
        candidate: initialReference.candidate,
        observationID: initialReference.observationID,
        generation: changed.generation)
    ])
    XCTAssertNil(persisted[initialReference.observationID]?.name)
  }

  func testAdoptionMigratesCandidateDisplayNameWithoutChangingTargetIdentity() async throws {
    let port = Port()
    let (owner, store) = try stack(port)
    let initial = try await owner.snapshot()
    let initialReference = try reference(initial)
    let named = try await owner.setDisplayName(initialReference, name: "Lab board")
    let namedReference = TargetObservationReference(
      candidate: initialReference.candidate,
      observationID: initialReference.observationID,
      generation: named.generation)

    let adopted = try await owner.adopt(namedReference)
    XCTAssertEqual(adopted.targetID, "TGT-\(adopted.stablePhysicalIdentitySHA256.prefix(12))")
    let durable = try store.targetDisplayName(targetID: adopted.targetID)
    XCTAssertEqual(durable.name, "Lab board")
    XCTAssertEqual(durable.generation, 2)
    let after = try await owner.snapshot(following: namedReference)
    XCTAssertNil(after.displayNames[initialReference.observationID]?.name)
    XCTAssertGreaterThan(after.generation, named.generation)
    let repeated = try await owner.adopt(namedReference)
    XCTAssertEqual(repeated, adopted, "exact retry returns one receipt")

    let reopened = try RuntimeTargetStore(directoryURL: directory)
    XCTAssertEqual(
      try reopened.targetDisplayName(targetID: adopted.targetID).name,
      "Lab board")
    XCTAssertEqual(try reopened.find(targetID: adopted.targetID), adopted)
  }

  func testExistingDurableTargetDisplayNameOutranksCandidateMigration() async throws {
    let port = Port()
    let (owner, store) = try stack(port)
    let identity = DeviceBootstrapMachine.stableIdentitySHA256(
      serial: "150100424a544e4600")
    let existing = try store.adopt(
      stableIdentitySHA256: identity, connectKey: "previous-provider-route",
      toolVersion: "3.2.0f", nowUTC: "2026-08-30T12:00:00Z").record
    _ = try store.setTargetDisplayName(
      targetID: existing.targetID, expectedGeneration: 1, name: "Durable name")

    let snapshot = try await owner.snapshot()
    let original = try reference(snapshot)
    let named = try await owner.setDisplayName(original, name: "Temporary name")
    let adopted = try await owner.adopt(
      .init(
        candidate: original.candidate, observationID: original.observationID,
        generation: named.generation))

    XCTAssertEqual(adopted, existing)
    let durable = try store.targetDisplayName(targetID: existing.targetID)
    XCTAssertEqual(durable.name, "Durable name")
    XCTAssertEqual(durable.generation, 2)
  }

  func testRuntimeRestartExpiresObservationScopedNames() async throws {
    let port = Port()
    let (owner, _) = try stack(port)
    let snapshot = try await owner.snapshot()
    let original = try reference(snapshot)
    let named = try await owner.setDisplayName(original, name: "Temporary cable")
    let namedReference = TargetObservationReference(
      candidate: original.candidate, observationID: original.observationID,
      generation: named.generation)

    let reopened = try RuntimeTargetStore(directoryURL: directory)
    let recovered = try reopened.candidateDisplayNames(references: [namedReference])
    XCTAssertNil(recovered[original.observationID]?.name)
    XCTAssertEqual(recovered[original.observationID]?.generation, named.generation)
  }
}
