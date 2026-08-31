import ArkDeckCore
import Foundation

/// Runtime-issued, lifecycle-scoped observation identity for discovery
/// candidates (§6.1, §8.5).
///
/// §8.5 states the rule in two halves: an observation ID binds durably to a
/// canonical candidate relation *the Runtime can prove is continuous*, and a
/// broken relation, an unprovable one, or a reused connect key must get a new
/// ID. On this platform the second half decides the first.
///
/// `hdc list targets -v` returns five columns — connect key, transport, state
/// and a literal `localhost` — and HDC 3.2 publishes no target event stream.
/// So between two polls a device can be unplugged and a different one attached
/// under the same connect key with no observable difference, and the only
/// "stable identity" reachable without a device round trip is
/// `SHA256(connectKey)`, which is a function of the very key §8.5 says must not
/// be followed. The Runtime therefore cannot prove continuity across
/// snapshots, and mints a fresh ID for every generation.
///
/// That is the conformant answer rather than a shortcut: persistence is what
/// §8.5 *permits* when continuity is provable, not what it requires, and
/// reissuing is what it *mandates* when continuity cannot be shown. But it is
/// a real limit with real consequences, so `continuity` publishes it instead
/// of leaving a caller to discover it: an ID must not be held across a
/// refresh, and `device wait`, whose contract is polling one observation
/// lifecycle across refreshes, is not implementable until discovery can prove
/// the relation — which needs a device-provided serial, i.e. a round trip per
/// candidate per refresh.
public struct DeviceObservationIdentity: Sendable, Equatable {

  /// What the Runtime can say about an observation ID's lifetime.
  ///
  /// Published so a caller branches on a fact rather than on a guess, and so
  /// the day discovery gains a provable relation this becomes
  /// `relationProven` without any consumer having to be told.
  public enum Continuity: String, Sendable, Equatable {
    /// The ID is valid only within its snapshot generation. A refresh mints a
    /// new one even for an unchanged connect key, because nothing observable
    /// distinguishes the same device from a different one reusing the key.
    case generationScoped
    /// The ID persists while the Runtime keeps proving the same relation.
    /// Nothing issues this yet.
    case relationProven
  }

  public static let continuity: Continuity = .generationScoped

  /// Why the continuity is what it is, in a form a caller can log verbatim
  /// when explaining to a person why an observation went stale.
  public static let continuityReason =
    "HDC discovery reports connect key, transport and state only, and publishes no target "
    + "event stream, so the Runtime cannot prove a candidate relation across snapshots"
}

/// Mints snapshot generations and observation IDs.
///
/// Not a store: there is nothing to persist, because no ID outlives its
/// generation. It exists so the minting rule has one home and one test, rather
/// than being an expression at the call site that later grows a special case.
public final class DeviceObservationRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private let newIdentifier: @Sendable () -> String

  /// The identifier source is injected so a test can pin it. §8.5 requires
  /// the ID to be opaque and to expose no transport string, which is why it is
  /// a fresh UUID rather than anything derived from the candidate: deriving it
  /// from the connect key would make equal keys produce equal IDs, and that is
  /// exactly the key-reuse continuity §8.5 forbids implying.
  public init(newIdentifier: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() })
  {
    self.newIdentifier = newIdentifier
  }

  /// Stamps one freshly observed snapshot: a new generation, and a new
  /// observation ID for every candidate in it.
  ///
  /// Called once per committed observation. Two candidates sharing a connect
  /// key inside one snapshot — which HDC can report while a device is
  /// transitioning — get two IDs, because they are two observations.
  public func stamp(_ snapshot: BootstrapCandidateSnapshot) -> BootstrapCandidateSnapshot {
    lock.withLock {
      generation &+= 1
      let stampedCandidates = snapshot.candidates.map { candidate in
        BootstrapCandidate(
          connectKey: candidate.connectKey,
          state: candidate.state,
          observationID: "obs-" + newIdentifier())
      }
      return BootstrapCandidateSnapshot(
        candidates: stampedCandidates,
        observedAtUTC: snapshot.observedAtUTC,
        health: snapshot.health,
        generation: generation)
    }
  }

  /// Re-publishes an already-stamped snapshot under a different health.
  ///
  /// A warm read reports the same observation with the same generation and the
  /// same IDs — only its freshness differs. Minting here instead would make
  /// every read look like a new observation and quietly break the one thing
  /// generation-scoped IDs are still good for: pinning an exact snapshot for
  /// `target adopt`.
  public func republish(
    _ snapshot: BootstrapCandidateSnapshot, health: BootstrapCandidateSnapshot.Health
  ) -> BootstrapCandidateSnapshot {
    BootstrapCandidateSnapshot(
      candidates: snapshot.candidates,
      observedAtUTC: snapshot.observedAtUTC,
      health: health,
      generation: snapshot.generation)
  }
}
