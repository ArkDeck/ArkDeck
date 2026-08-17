import CryptoKit
import Foundation

/// Deciding which device the daemon observed is the one ArkDeck bound.
///
/// This is the single most dangerous join in the lane. ArkDeck holds a binding
/// — a connect key, a stable identity, a port path — and the daemon holds its
/// own sightings; a plan materialized against the wrong sighting is a plan
/// that would write nine partitions to a board nobody chose.
///
/// # Why the port path, and not the id
///
/// `observationID` is an `OpaqueId` on the daemon's side and is treated as
/// opaque here: parsing `USB-2207-5000-01200000` for its parts would couple
/// this repository to a format the other one is free to change, and would fail
/// silently rather than loudly when it did.
///
/// What crosses the boundary honestly is `topologyDigest`, which both sides
/// derive from the same physical fact by a published rule
/// (`arkforge-transport::UsbDeviceRecord::topology_digest`):
///
/// ```text
/// SHA-256( "arkforge/v1/device-facts\0" || locationID_be32 )
/// ```
///
/// ArkDeck already carries that `locationID` as its `usbTopology`
/// (`RockchipFlashExecutionHost` stores `String(location.uint64Value)`), so
/// this recomputes the digest and matches on it. Verified against the attached
/// board on 2026-08-17: `ioreg` reports `locationID = 18874368`, and the
/// daemon's observation is `USB-2207-5000-01200000` — `0x01200000` is that
/// same number.
public enum ArkForgeObservationSelection {

  /// The domain prefix, including the trailing NUL that keeps one domain from
  /// being a prefix of another.
  static let deviceFactsDomain = Array("arkforge/v1/device-facts\0".utf8)

  public enum SelectionFailure: Error, Equatable, CustomStringConvertible {
    case unusableTopology(String)
    case noObservationForBoundDevice(topology: String, observed: [String])
    case ambiguous(topology: String, matches: [String])

    public var description: String {
      switch self {
      case .unusableTopology(let raw):
        return
          "the bound device's usbTopology \(raw.isEmpty ? "is empty" : "is \(raw)"), which is "
          + "not a USB location id; without it there is no way to tell the daemon which board "
          + "this job is about"
      case .noObservationForBoundDevice(let topology, let observed):
        return
          "the daemon sees no device at the port this job is bound to (\(topology)); it "
          + "observed \(observed.isEmpty ? "nothing" : observed.joined(separator: ", ")). "
          + "Nothing was materialized — a plan built against a device the daemon cannot see "
          + "is a plan for some other board"
      case .ambiguous(let topology, let matches):
        return
          "\(matches.count) observations claim port \(topology): \(matches.joined(separator: ", ")). "
          + "Refusing rather than picking one, because the tie is between candidates for a "
          + "destructive write"
      }
    }
  }

  /// The digest the daemon would compute for this port path.
  ///
  /// `nil` when `usbTopology` is not a number that fits a USB location id. It
  /// is a `UInt32` on the daemon's side, and a value that does not fit is a
  /// value the two sides could not have derived from the same fact.
  public static func topologyDigest(usbTopology: String) -> String? {
    let trimmed = usbTopology.trimmingCharacters(in: .whitespaces)
    guard let location = UInt32(trimmed) else { return nil }
    var hasher = SHA256()
    hasher.update(data: Data(deviceFactsDomain))
    hasher.update(data: Data([
      UInt8(truncatingIfNeeded: location >> 24), UInt8(truncatingIfNeeded: location >> 16),
      UInt8(truncatingIfNeeded: location >> 8), UInt8(truncatingIfNeeded: location),
    ]))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// The one observation for the bound device, or why there isn't one.
  ///
  /// Exactly one, never "the first". Zero means the daemon cannot see the
  /// board this job is about; more than one means two sightings claim the same
  /// port, which should be impossible and is therefore exactly the moment to
  /// stop rather than to choose.
  public static func select(
    observations: [ArkForgeDeviceObservation], usbTopology: String
  ) -> Result<ArkForgeDeviceObservation, SelectionFailure> {
    guard let wanted = topologyDigest(usbTopology: usbTopology) else {
      return .failure(.unusableTopology(usbTopology))
    }
    let matches = observations.filter { $0.topologyDigest.lowercased() == wanted }
    switch matches.count {
    case 1: return .success(matches[0])
    case 0:
      return .failure(
        .noObservationForBoundDevice(
          topology: usbTopology, observed: observations.map(\.observationID)))
    default:
      return .failure(
        .ambiguous(topology: usbTopology, matches: matches.map(\.observationID)))
    }
  }
}
