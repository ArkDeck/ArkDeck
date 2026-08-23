import Foundation
import XCTest

@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

final class ArkForgeLoaderObservationContractTests: XCTestCase {
  private final class CountingUSBProbe: @unchecked Sendable, RockchipRuntimeUSBProbing {
    private let lock = NSLock()
    private var reads = 0
    let identity: RockchipRuntimeLoaderIdentity

    init(identity: RockchipRuntimeLoaderIdentity) {
      self.identity = identity
    }

    var loaderReads: Int {
      lock.lock()
      defer { lock.unlock() }
      return reads
    }

    func singleLoader(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      lock.lock()
      reads += 1
      lock.unlock()
      return identity
    }

    func singleHDCNormal(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw ProbeFailure.absent
    }
  }

  private struct USBProbe: RockchipRuntimeUSBProbing {
    let loader: Result<RockchipRuntimeLoaderIdentity, ProbeFailure>

    func singleLoader(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      try loader.get()
    }

    func singleHDCNormal(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw ProbeFailure.absent
    }

    func singleHDCNormal(
      usbTopology _: String
    ) throws -> RockchipRuntimeHDCIdentity {
      throw ProbeFailure.absent
    }
  }

  private enum ProbeFailure: Error {
    case absent
  }

  private let identity = String(repeating: "a4", count: 32)
  private let topology = "17956864"

  private func observation(
    mode: String = "rockusb-loader",
    strength: String = "serialAndTopology",
    malformed: Bool = false,
    usbIdentity: String = "0x2207:0x350a"
  ) -> ArkForgeDeviceObservation {
    ArkForgeDeviceObservation(
      observationID: "USB-2207-350a-01120000",
      observedAtEpochMS: 1_000,
      mode: mode,
      topologyDigest: ArkForgeObservationSelection.topologyDigest(
        usbTopology: topology)!,
      descriptorDigest: String(repeating: "d", count: 64),
      identityStrength: strength,
      malformedDescriptor: malformed,
      protocolIdentity: ["usb.identity": usbIdentity, "profile": "dayu200-native-rockusb"])
  }

  private func observer(
    probe: USBProbe? = nil,
    observations: [ArkForgeDeviceObservation]? = nil
  ) -> ProductArkForgeLoaderObserver {
    let discovered = observations ?? [observation()]
    return ProductArkForgeLoaderObserver(
      usbProbe: probe ?? USBProbe(
        loader: .success(
          RockchipRuntimeLoaderIdentity(
            serialDigestSHA256: identity, topology: topology))),
      discover: { _ in discovered })
  }

  func testIOKitAndArkForgeMustAgreeOnOneExactLoader() throws {
    let observed = try observer().observeLoader(
      stableIdentitySHA256: identity,
      expectedUSBTopology: topology,
      requestID: "REQ-dual-source")

    XCTAssertEqual(observed.serialDigestSHA256, identity)
    XCTAssertEqual(observed.topology, topology)
  }

  func testFreshIOKitIdentityCanBeConfirmedWithoutImmediateSecondEnumeration() throws {
    let exact = RockchipRuntimeLoaderIdentity(
      serialDigestSHA256: identity, topology: topology)
    let probe = CountingUSBProbe(identity: exact)
    let discovered = observation()
    let observer = ProductArkForgeLoaderObserver(
      usbProbe: probe,
      discover: { _ in [discovered] })

    let confirmed = try observer.confirmLoader(
      exact,
      stableIdentitySHA256: identity,
      expectedUSBTopology: topology,
      requestID: "REQ-preobserved-iokit")

    XCTAssertEqual(confirmed, exact)
    XCTAssertEqual(
      probe.loaderReads, 0,
      "the caller's same-descriptor IOKit read must not be repeated")
    _ = try observer.observeLoader(
      stableIdentitySHA256: identity,
      expectedUSBTopology: topology,
      requestID: "REQ-full-observation")
    XCTAssertEqual(probe.loaderReads, 1)
  }

  func testIOKitAloneIsInsufficient() {
    XCTAssertThrowsError(
      try observer(observations: []).observeLoader(
        stableIdentitySHA256: identity,
        expectedUSBTopology: topology,
        requestID: "REQ-no-daemon-observation")
    ) { error in
      guard case ArkForgeLoaderObservationFailure.selection = error else {
        return XCTFail("expected the missing ArkForge source to refuse, got \(error)")
      }
    }
  }

  func testArkForgeAloneIsInsufficient() {
    XCTAssertThrowsError(
      try observer(probe: USBProbe(loader: .failure(.absent))).observeLoader(
        stableIdentitySHA256: identity,
        expectedUSBTopology: topology,
        requestID: "REQ-no-iokit-observation")
    ) { error in
      guard case ArkForgeLoaderObservationFailure.iokit = error else {
        return XCTFail("expected the missing IOKit source to refuse, got \(error)")
      }
    }
  }

  func testWeakMalformedOrWrongModeDaemonObservationsAreRejected() {
    for bad in [
      observation(mode: "maskrom"),
      observation(strength: "classOnly"),
      observation(malformed: true),
      observation(usbIdentity: "0x2207:0x350b"),
    ] {
      XCTAssertThrowsError(
        try observer(observations: [bad]).observeLoader(
          stableIdentitySHA256: identity,
          expectedUSBTopology: topology,
          requestID: "REQ-bad-daemon-observation"))
    }
  }

  func testAdmittedTopologyDriftIsRejectedBeforeDaemonSelection() {
    XCTAssertThrowsError(
      try observer().observeLoader(
        stableIdentitySHA256: identity,
        expectedUSBTopology: "18874368",
        requestID: "REQ-topology-drift")
    ) { error in
      XCTAssertEqual(
        error as? ArkForgeLoaderObservationFailure,
        .topologyMismatch(expected: "18874368", observed: topology))
    }
  }
}
