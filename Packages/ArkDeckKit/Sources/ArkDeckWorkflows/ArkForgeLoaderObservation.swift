import ArkForgeClient
import ArkForgeProtocol
import Foundation

/// The read-only half of Loader identity that ArkDeck and ArkForge must agree on.
///
/// IOKit proves the exact bound serial and current USB location. ArkForge proves,
/// through its independently enumerated DeviceObservation, that the device at
/// that location is a settled DAYU200 RockUSB Loader. Neither source is enough
/// on its own: accepting IOKit alone would lose the provider/mode observation,
/// while accepting ArkForge alone would lose ArkDeck's bound target identity.
protocol ArkForgeLoaderObserving: Sendable {
  func observeLoader(
    stableIdentitySHA256: String,
    expectedUSBTopology: String?,
    requestID: String
  ) throws -> RockchipRuntimeLoaderIdentity

  /// Confirms ArkForge's independent observation against an IOKit identity
  /// the caller has just read from the same descriptor. Production uses this
  /// to avoid immediately enumerating IOKit a second time; test and alternate
  /// observers retain the original API through the conservative default.
  func confirmLoader(
    _ identity: RockchipRuntimeLoaderIdentity,
    stableIdentitySHA256: String,
    expectedUSBTopology: String?,
    requestID: String
  ) throws -> RockchipRuntimeLoaderIdentity
}

extension ArkForgeLoaderObserving {
  func confirmLoader(
    _: RockchipRuntimeLoaderIdentity,
    stableIdentitySHA256: String,
    expectedUSBTopology: String?,
    requestID: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    try observeLoader(
      stableIdentitySHA256: stableIdentitySHA256,
      expectedUSBTopology: expectedUSBTopology,
      requestID: requestID)
  }
}

enum ArkForgeLoaderObservationFailure: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case iokit(String)
  case identityMismatch
  case topologyMismatch(expected: String, observed: String)
  case daemon(String)
  case selection(String)
  case unusableObservation(String)

  var description: String {
    switch self {
    case .iokit(let detail):
      return "IOKit did not observe the exact bound Loader: \(detail)"
    case .identityMismatch:
      return "IOKit Loader identity does not match the bound target"
    case .topologyMismatch(let expected, let observed):
      return
        "IOKit observed the bound Loader at USB topology \(observed), not the admitted "
        + "topology \(expected)"
    case .daemon(let detail):
      return "arkforged discoverDevices is unavailable: \(detail)"
    case .selection(let detail):
      return "arkforged did not uniquely observe the bound Loader: \(detail)"
    case .unusableObservation(let detail):
      return "arkforged returned an unusable Loader observation: \(detail)"
    }
  }
}

/// Production dual-source observation. The socket is the daemon's read-only
/// public surface; this type has no execution API and cannot submit a permit or
/// dispatch a device effect.
struct ProductArkForgeLoaderObserver: ArkForgeLoaderObserving {
  private let usbProbe: any RockchipRuntimeUSBProbing
  private let discover: @Sendable (String) throws -> [ArkForgeDeviceObservation]

  init(
    runtimeDirectory: URL,
    usbProbe: any RockchipRuntimeUSBProbing = ProductRockchipRuntimeUSBProbe()
  ) {
    self.usbProbe = usbProbe
    let socketPath = runtimeDirectory.appending(path: "public.sock").path
    self.discover = { requestID in
      let client = try ArkForgePublicClient(socketPath: socketPath, timeoutSeconds: 15)
      return try client.discoverDevices(requestID: requestID)
    }
  }

  init(
    usbProbe: any RockchipRuntimeUSBProbing,
    discover: @escaping @Sendable (String) throws -> [ArkForgeDeviceObservation]
  ) {
    self.usbProbe = usbProbe
    self.discover = discover
  }

  func observeLoader(
    stableIdentitySHA256: String,
    expectedUSBTopology: String?,
    requestID: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    let identity: RockchipRuntimeLoaderIdentity
    do {
      identity = try usbProbe.singleLoader(
        stableIdentitySHA256: stableIdentitySHA256)
    } catch {
      throw ArkForgeLoaderObservationFailure.iokit("\(error)")
    }
    return try confirmLoader(
      identity,
      stableIdentitySHA256: stableIdentitySHA256,
      expectedUSBTopology: expectedUSBTopology,
      requestID: requestID)
  }

  func confirmLoader(
    _ identity: RockchipRuntimeLoaderIdentity,
    stableIdentitySHA256: String,
    expectedUSBTopology: String?,
    requestID: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    guard identity.serialDigestSHA256 == stableIdentitySHA256 else {
      throw ArkForgeLoaderObservationFailure.identityMismatch
    }
    if let expectedUSBTopology, !expectedUSBTopology.isEmpty,
      identity.topology != expectedUSBTopology
    {
      throw ArkForgeLoaderObservationFailure.topologyMismatch(
        expected: expectedUSBTopology, observed: identity.topology)
    }

    let observations: [ArkForgeDeviceObservation]
    do {
      observations = try discover(requestID)
    } catch {
      throw ArkForgeLoaderObservationFailure.daemon("\(error)")
    }
    let observation: ArkForgeDeviceObservation
    switch ArkForgeObservationSelection.select(
      observations: observations, usbTopology: identity.topology)
    {
    case .success(let selected):
      observation = selected
    case .failure(let failure):
      throw ArkForgeLoaderObservationFailure.selection("\(failure)")
    }
    guard observation.mode == "rockusb-loader" else {
      throw ArkForgeLoaderObservationFailure.unusableObservation(
        "mode is \(observation.mode), expected rockusb-loader")
    }
    guard observation.identityStrength == "serialAndTopology" else {
      throw ArkForgeLoaderObservationFailure.unusableObservation(
        "identity strength is \(observation.identityStrength), expected serialAndTopology")
    }
    guard !observation.malformedDescriptor else {
      throw ArkForgeLoaderObservationFailure.unusableObservation(
        "the USB descriptor is marked malformed")
    }
    guard observation.protocolIdentity["usb.identity"] == "0x2207:0x350a" else {
      throw ArkForgeLoaderObservationFailure.unusableObservation(
        "USB class is not the registered DAYU200 Loader")
    }
    return identity
  }
}

struct RefusingArkForgeLoaderObserver: ArkForgeLoaderObserving {
  let reason: String

  func observeLoader(
    stableIdentitySHA256 _: String,
    expectedUSBTopology _: String?,
    requestID _: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    throw ArkForgeLoaderObservationFailure.daemon(reason)
  }
}
