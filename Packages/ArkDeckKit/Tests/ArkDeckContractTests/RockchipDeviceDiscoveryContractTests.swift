import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Product-facing discovery is a typed projection of ArkForge observations.
/// ArkDeck no longer selects, launches, parses or trusts a separate vendor tool.
final class RockchipDeviceDiscoveryContractTests: XCTestCase {
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
}
