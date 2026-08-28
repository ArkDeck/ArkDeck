import Foundation
import XCTest

@testable import ArkDeckWorkflows
@testable import ArkForgeProtocol

/// Product-facing access advice is a typed projection of ArkForge observations.
/// ArkDeck no longer selects, launches, parses or trusts a separate vendor tool.
final class RockchipDeviceAccessAdvisorContractTests: XCTestCase {
  func testAccessAdvisorKeepsFailureFamiliesDistinctAndActionable() {
    let cases:
      [(
        RockchipDeviceAccessVerdict,
        RockchipDeviceAccessResponsibility,
        RockchipDeviceAccessRemediation
      )] = [
        (.accessible, .user, .chooseSupportedLoaderObservation),
        (.offlineOrUnauthorized, .user, .reconnectOrEnterLoader),
        (.permissionDenied, .systemAdministrator, .reviewDevicePermissionOutsideArkDeck),
        (.driverUnavailable, .deviceOrToolVendor, .repairDriverOutsideArkDeck),
        (.protocolBlocked, .user, .chooseSupportedLoaderObservation),
        (.malformedOutput, .deviceOrToolVendor, .inspectControlledDiagnostics),
        (.probeFailed, .deviceOrToolVendor, .inspectControlledDiagnostics),
      ]

    for (verdict, responsibility, remediation) in cases {
      let advice = RockchipDeviceAccessAdvisor.advice(for: verdict)
      XCTAssertEqual(advice.verdict, verdict)
      XCTAssertEqual(advice.responsibility, responsibility)
      XCTAssertEqual(advice.remediation, remediation)
      XCTAssertTrue(advice.reprobeAvailable)
    }
  }

  func testFlashApplicationFacadeProjectsArkForgeReadOnlyDiscovery() async {
    let provider = RockchipDeviceAccessApplicationFacade.make(
      arguments: ["ArkDeck", "--ui-test-flash"])

    let presentation = await provider.refresh()

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.advice?.verdict, .accessible)
    XCTAssertEqual(presentation.observationCount, 1)
    XCTAssertEqual(presentation.observedModes, [.loader])
  }

  func testProductionAppUsesOnlyTheReadOnlyRuntimeProjection() async {
    let provider = RockchipDeviceAccessProductionProvider { method in
      XCTAssertEqual(method, "flash.device-access")
      return .success(Data(#"{"ok":true,"result":{"observationCount":1,"observedModes":["Loader"]}}"#.utf8))
    }
    let presentation = await provider.refresh()
    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.advice?.verdict, .accessible)
    XCTAssertEqual(presentation.observedModes, [.loader])
  }

  func testAbsentAndMaskromStayDistinctFromUnreachableOrMalformedDiscovery() {
    for (json, verdict) in [
      (#"{"ok":true,"result":{"observationCount":0,"observedModes":[]}}"#, RockchipDeviceAccessVerdict.offlineOrUnauthorized),
      (#"{"ok":true,"result":{"observationCount":1,"observedModes":["Maskrom"]}}"#, .protocolBlocked),
    ] {
      let presentation = RockchipDeviceAccessResponseDecoding.presentation(.success(Data(json.utf8)))
      XCTAssertEqual(presentation.availability, .available)
      XCTAssertEqual(presentation.advice?.verdict, verdict)
    }
    let failures: [RuntimeXPCRequestTransport.ResultValue] = [
      .failure(.unavailable("private socket path")),
      .failure(.timedOut),
      .success(Data(#"{"ok":false,"error":{"message":"private device identity"}}"#.utf8)),
      .success(Data(#"{"ok":true,"result":{"observationCount":-1,"observedModes":[]}}"#.utf8)),
      .success(Data(#"{"ok":true,"result":{"observationCount":true,"observedModes":["Loader"]}}"#.utf8)),
      .success(Data(#"{"ok":true,"result":{"observationCount":2,"observedModes":["Loader"]}}"#.utf8)),
      .success(Data(#"{"ok":true,"result":{"observationCount":1,"observedModes":["future-mode"]}}"#.utf8)),
      .success(Data(#"{"ok":true}"#.utf8)),
    ]
    for response in failures {
      let presentation = RockchipDeviceAccessResponseDecoding.presentation(response)
      guard case .unavailable(let reason) = presentation.availability else {
        return XCTFail("failed discovery must not become an empty successful observation")
      }
      XCTAssertFalse(reason.contains("private"))
      XCTAssertNotEqual(presentation.advice?.verdict, .accessible)
      XCTAssertTrue(presentation.observedModes.isEmpty)
    }
  }

  func testRuntimeObserverUsesArkForgeModesAndPropagatesProbeFailure() throws {
    let observations = ["rockusb-loader", "loader", "rockusb-maskrom", "maskrom", "hdcNormal"].map {
      ArkForgeDeviceObservation(
        observationID: "private-usb-identity", observedAtEpochMS: 1_000, mode: $0,
        topologyDigest: String(repeating: "a", count: 64),
        descriptorDigest: String(repeating: "b", count: 64),
        identityStrength: "serialAndTopology", malformedDescriptor: false,
        protocolIdentity: ["profile": "dayu200-native-rockusb"])
    }
    let observer = ProductRockchipDeviceAccessObserver(discover: { observations })
    XCTAssertEqual(try observer.observeDeviceAccess(), [.loader, .loader, .maskrom, .maskrom])
    struct ProbeFailure: Error {}
    let failing = ProductRockchipDeviceAccessObserver(discover: { throw ProbeFailure() })
    XCTAssertThrowsError(try failing.observeDeviceAccess())
  }
}
