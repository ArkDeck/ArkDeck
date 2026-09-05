import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Presentation-cache observation identity remains separate from the current
/// Runtime owner, whose continuity requires independent USB proof.
///
/// The section permits an observation ID to persist across generations only
/// while the Runtime can prove the same candidate relation, and *requires* a
/// new ID when the relation breaks or a connect key is reused. On this
/// platform discovery reports connect key, transport and state and nothing
/// else, so continuity is never provable and the second clause governs
/// everything. These tests pin that reading, because the tempting shortcut —
/// keying the ID off the connect key so it "stays stable" — is precisely the
/// key-reuse continuity §8.5 forbids implying.
final class DeviceObservationIdentityContractTests: XCTestCase {

  private func registry() -> DeviceObservationRegistry {
    let counter = Counter()
    return DeviceObservationRegistry(newIdentifier: { counter.next() })
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String {
      lock.withLock {
        value += 1
        return "id\(value)"
      }
    }
  }

  private func snapshot(_ keys: [String]) -> BootstrapCandidateSnapshot {
    BootstrapCandidateSnapshot(
      candidates: keys.map { BootstrapCandidate(connectKey: $0, state: "Connected") },
      observedAtUTC: "2026-08-31T00:00:00Z", health: .current)
  }

  func testEachObservationGetsAFreshIdentityAndTheGenerationAdvances() {
    let registry = registry()
    let first = registry.stamp(snapshot(["dev-a", "dev-b"]))
    XCTAssertEqual(first.generation, 1)
    XCTAssertEqual(first.candidates.compactMap(\.observationID), ["obs-id1", "obs-id2"])

    let second = registry.stamp(snapshot(["dev-a", "dev-b"]))
    XCTAssertEqual(second.generation, 2, "a committed observation advances the generation")
    XCTAssertEqual(second.candidates.compactMap(\.observationID), ["obs-id3", "obs-id4"])
  }

  /// The assertion that carries the safety property. The same connect key
  /// across two snapshots is *not* evidence of the same device — HDC publishes
  /// no event stream, so a swap between polls is unobservable. An ID that
  /// stayed equal would tell `target adopt --observation` that continuity was
  /// proven when nothing proved it.
  func testAnUnchangedConnectKeyStillGetsANewIdentityInTheNextGeneration() {
    let registry = registry()
    let first = registry.stamp(snapshot(["dev-a"]))
    let second = registry.stamp(snapshot(["dev-a"]))
    XCTAssertNotEqual(
      first.candidates[0].observationID, second.candidates[0].observationID,
      "connect-key equality is not relation continuity, and must not mint the same ID")
    XCTAssertEqual(first.candidates[0].connectKey, second.candidates[0].connectKey)
  }

  /// HDC can list a key twice while a device transitions. Two rows are two
  /// observations, so they get two identities rather than being collapsed.
  func testTwoRowsSharingAConnectKeyInOneSnapshotAreTwoObservations() {
    let stamped = registry().stamp(snapshot(["dev-a", "dev-a"]))
    let ids = stamped.candidates.compactMap(\.observationID)
    XCTAssertEqual(ids.count, 2)
    XCTAssertNotEqual(ids[0], ids[1])
  }

  /// A warm read is the same observation seen again, so it keeps its
  /// generation and its IDs. Re-minting here would make every read look like a
  /// new observation and destroy the one guarantee a generation-scoped ID
  /// still provides: that it pins an exact snapshot for `target adopt`.
  func testAWarmRepublishKeepsTheGenerationAndTheIdentities() {
    let registry = registry()
    let stamped = registry.stamp(snapshot(["dev-a"]))
    let warm = registry.republish(stamped, health: .stale)
    XCTAssertEqual(warm.generation, stamped.generation)
    XCTAssertEqual(warm.candidates.map(\.observationID), stamped.candidates.map(\.observationID))
    XCTAssertEqual(warm.health, .stale, "only the freshness differs")
  }

  /// The ID must be opaque and must not expose a transport string (§8.5).
  /// Deriving it from the connect key would do both, and would additionally
  /// make equal keys produce equal IDs.
  func testTheIdentityIsOpaqueAndCarriesNoTransportString() {
    let stamped = registry().stamp(snapshot(["127.0.0.1:5555"]))
    let id = try? XCTUnwrap(stamped.candidates[0].observationID)
    XCTAssertNotNil(id)
    XCTAssertFalse(id?.contains("127.0.0.1") ?? true)
    XCTAssertFalse(id?.contains("5555") ?? true)
  }

  func testPresentationCacheIdentitiesCannotAdoptThroughTheCurrentOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "observation-owner-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let targets = try RuntimeTargetStore(directoryURL: root)
    let port = TargetObservationCoordinatorContractTests.Port()
    let owner = TargetObservationCoordinator(observation: port, targetStore: targets,
      usbRelations: { try port.relations() }, nowUTC: { "2026-08-31T00:00:00Z" })
    let cache = registry().stamp(snapshot(["150100424a544e4600"]))
    let current = try await owner.snapshot()
    let row = try XCTUnwrap(current.observations.first)
    XCTAssertEqual(row.continuity, "relationProven")
    XCTAssertNotEqual(row.observationID, cache.candidates.first?.observationID)
    do {
      _ = try await owner.adopt(TargetObservationReference(candidate: row.candidate.connectKey,
        observationID: try XCTUnwrap(cache.candidates.first?.observationID), generation: current.generation))
      XCTFail("a presentation cache identity cannot select a current Runtime observation")
    } catch let error as TargetObservationFailure { XCTAssertEqual(error.code, "resourceConflict") }
    XCTAssertTrue(try targets.list().isEmpty)
    _ = try await owner.adopt(TargetObservationReference(candidate: row.candidate.connectKey,
      observationID: row.observationID, generation: current.generation))
    XCTAssertEqual(try targets.list().count, 1)
  }

  func testAnUnstampedPresentationSnapshotHasNoRuntimeIdentity() throws {
    let raw = snapshot(["dev-a"])
    XCTAssertNil(raw.generation)
    XCTAssertNil(raw.candidates.first?.observationID)
  }
}
