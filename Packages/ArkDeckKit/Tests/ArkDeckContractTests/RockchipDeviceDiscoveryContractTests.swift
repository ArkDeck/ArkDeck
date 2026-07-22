import ArkDeckProcess
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// TASK-RKFUI-001 contract/fake coverage only. The suite launches `/usr/bin/true`
/// as a no-output process control; it never invokes rkdeveloptool or accesses a device.
final class RockchipDeviceDiscoveryContractTests: XCTestCase {
  private struct Registry: Decodable {
    let schemaVersion: String
    let serializationFormat: String
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let unknownFamilyDisposition: String
    let toolContext: ToolContext
    let operation: Operation

    struct ToolContext: Decodable {
      let platform: String
      let reportedVersion: String
      let executableSHA256: String
      let upstreamCommit: String
      let pathSource: String
      let platformTrustRequired: Bool
      let quarantineAllowed: Bool
    }

    struct Operation: Decodable {
      let family: String
      let status: String
      let exactArgv: [String]
      let effectClassification: String
      let timeoutMilliseconds: Int
      let maximumOutputBytes: Int
      let maximumDeviceCount: Int
      let wholeOutputConsumed: Bool
      let duplicateDeviceNumberDisposition: String
      let duplicateLocationIDDisposition: String
      let unknownModeDisposition: String
      let forbiddenEffects: [String]
    }
  }

  private struct ResourceManifest: Decodable {
    let schemaVersion: String
    let registryId: String
    let registryVersion: String
    let resources: [Resource]

    struct Resource: Decodable {
      let id: String
      let path: String
      let sha256: String
      let sizeBytes: Int
      let evidenceClass: String
    }
  }

  private final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  // MARK: - Registry/resource closure

  func testRegistryPinsOneReadOnlyIdentityBoundLDOperationAndAllFixtureBytes() throws {
    let registry = try JSONDecoder().decode(
      Registry.self, from: Data(contentsOf: bundledRegistryURL()))
    let profile = RockchipDiscoveryIntegrationProfile.pinnedProduction

    XCTAssertEqual(registry.schemaVersion, "1.0.0")
    XCTAssertEqual(registry.serializationFormat, "json-compatible-yaml-1.2")
    XCTAssertEqual(registry.registryId, "ROCKCHIP-ROCKUSB-DISCOVERY")
    XCTAssertEqual(registry.registryVersion, "1.0.0")
    XCTAssertEqual(registry.integrationProfile, profile.identifier)
    XCTAssertEqual(registry.unknownFamilyDisposition, "blocked")
    XCTAssertEqual(registry.toolContext.platform, "macos")
    XCTAssertEqual(registry.toolContext.reportedVersion, profile.reportedToolVersion)
    XCTAssertEqual(registry.toolContext.executableSHA256, profile.executableSHA256)
    XCTAssertEqual(registry.toolContext.upstreamCommit, profile.upstreamCommit)
    XCTAssertEqual(registry.toolContext.pathSource, "userSelectedSecurityScopedBookmark")
    XCTAssertTrue(registry.toolContext.platformTrustRequired)
    XCTAssertFalse(registry.toolContext.quarantineAllowed)
    XCTAssertEqual(registry.operation.family, "rockusbListDevices")
    XCTAssertEqual(registry.operation.status, "supported")
    XCTAssertEqual(registry.operation.exactArgv, ["ld"])
    XCTAssertEqual(registry.operation.exactArgv, profile.exactArguments)
    XCTAssertEqual(registry.operation.effectClassification, "readOnly")
    XCTAssertEqual(registry.operation.timeoutMilliseconds, 5_000)
    XCTAssertEqual(registry.operation.maximumOutputBytes, 65_536)
    XCTAssertEqual(registry.operation.maximumDeviceCount, 64)
    XCTAssertTrue(registry.operation.wholeOutputConsumed)
    XCTAssertEqual(registry.operation.duplicateDeviceNumberDisposition, "blocked")
    XCTAssertEqual(registry.operation.duplicateLocationIDDisposition, "blocked")
    XCTAssertEqual(registry.operation.unknownModeDisposition, "blocked")

    let expectedForbiddenEffects: Set<String> = [
      "shell", "sudo", "hostPrivilegeElevation", "helperInstall", "driverInstall",
      "systemRuleWrite", "groupOrACLMutation", "globalDevicePermissionReduction", "modeSwitch",
      "deviceMutation", "destructive",
    ]
    XCTAssertEqual(Set(registry.operation.forbiddenEffects), expectedForbiddenEffects)

    let manifest = try JSONDecoder().decode(
      ResourceManifest.self, from: Data(contentsOf: bundledResourceManifestURL()))
    XCTAssertEqual(manifest.schemaVersion, "1.0.0")
    XCTAssertEqual(manifest.registryId, registry.registryId)
    XCTAssertEqual(manifest.registryVersion, registry.registryVersion)
    XCTAssertEqual(manifest.resources.count, 10)
    XCTAssertEqual(Set(manifest.resources.map(\.id)).count, manifest.resources.count)
    let manifestPathPrefix =
      "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Rockchip/Discovery/1.0.0/"
    for resource in manifest.resources {
      XCTAssertTrue(resource.path.hasPrefix(manifestPathPrefix), resource.id)
      let relativePath = String(resource.path.dropFirst(manifestPathPrefix.count))
      let bytes = try Data(contentsOf: fixtureRoot().appending(path: relativePath))
      XCTAssertEqual(bytes.count, resource.sizeBytes, resource.id)
      XCTAssertEqual(sha256(bytes), resource.sha256, resource.id)
      XCTAssertFalse(resource.evidenceClass.isEmpty)
    }
  }

  // MARK: - TEST-AC-FLASH-001-01

  func testTEST_AC_FLASH_001_01_StrictGoldenAndMultiDeviceFamiliesAreFullyConsumed() throws {
    let single = RockchipLDOutputParser.parse(
      stdout: try fixture("success-single-loader.stdout.bin"))
    guard case .observations(let singleObservations) = single else {
      return XCTFail("registered single-Loader family must parse: \(single)")
    }
    XCTAssertEqual(singleObservations.count, 1)
    XCTAssertEqual(singleObservations[0].deviceNumber, 1)
    XCTAssertEqual(singleObservations[0].usbVendorID, 0x2207)
    XCTAssertEqual(singleObservations[0].usbProductID, 0x350a)
    XCTAssertEqual(singleObservations[0].locationID, 2)
    XCTAssertEqual(singleObservations[0].mode, .loader)
    XCTAssertEqual(singleObservations[0].providerPreflightDisposition, .applicableLoader)

    let multi = RockchipLDOutputParser.parse(stdout: try fixture("success-multi-device.stdout.bin"))
    guard case .observations(let multiObservations) = multi else {
      return XCTFail("distinct multi-device rows must remain visible: \(multi)")
    }
    XCTAssertEqual(multiObservations.count, 2)
    XCTAssertEqual(multiObservations.map(\.deviceNumber), [1, 2])
    XCTAssertEqual(multiObservations.map(\.locationID), [2, 5])
    XCTAssertEqual(multiObservations.map(\.mode), [.loader, .maskrom])
    XCTAssertEqual(RockchipDeviceAccessAdvisor.verdict(for: multi), .accessible)
  }

  func testTEST_AC_FLASH_001_01_MaskromSimilarMalformedDuplicateAndUnknownBlockWithoutGuessing()
    throws
  {
    for name in ["maskrom.stdout.bin", "similar-family.stdout.bin"] {
      let parsed = RockchipLDOutputParser.parse(stdout: try fixture(name))
      guard case .observations(let observations) = parsed else {
        return XCTFail("known blocked observation must remain diagnosable: \(name)")
      }
      XCTAssertEqual(observations.count, 1)
      guard case .blocked = observations[0].providerPreflightDisposition else {
        return XCTFail("\(name) must not be applicable to the Loader Provider")
      }
      XCTAssertEqual(RockchipDeviceAccessAdvisor.verdict(for: parsed), .protocolBlocked)
    }

    XCTAssertEqual(
      RockchipLDOutputParser.parse(stdout: try fixture("malformed-missing-tab.stdout.bin")),
      .blocked(.malformedLine(line: 1)))
    XCTAssertEqual(
      RockchipLDOutputParser.parse(stdout: try fixture("duplicate-device-number.stdout.bin")),
      .blocked(.duplicateDeviceNumber(1)))
    XCTAssertEqual(
      RockchipLDOutputParser.parse(stdout: try fixture("duplicate-location.stdout.bin")),
      .blocked(.duplicateLocationID(2)))
    XCTAssertEqual(
      RockchipLDOutputParser.parse(stdout: try fixture("unknown-mode.stdout.bin")),
      .blocked(.unknownMode(line: 1, value: "Recovery")))

    let validPlusGarbage = try fixture("success-single-loader.stdout.bin") + Data("ignored\n".utf8)
    XCTAssertEqual(
      RockchipLDOutputParser.parse(stdout: validPlusGarbage),
      .blocked(.malformedLine(line: 2)))

    let carriageReturnOutput = Data(
      "DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=2\tLoader\r\n".utf8)
    let carriageReturnResult = RockchipLDOutputParser.parse(stdout: carriageReturnOutput)
    XCTAssertEqual(carriageReturnResult, .blocked(.unexpectedCarriageReturn))
    XCTAssertEqual(
      RockchipDeviceAccessAdvisor.verdict(for: carriageReturnResult), .malformedOutput)

    XCTAssertEqual(
      RockchipLDOutputParser.parse(
        stdout: Data(repeating: 0x41, count: RockchipLDOutputParser.maximumOutputBytes + 1)),
      .blocked(.outputTooLarge))
    print(
      "TEST-AC-FLASH-001-01 PASS success=1 multi=1 maskrom=blocked "
        + "similar=blocked malformed=blocked duplicate=blocked unknown=blocked similar_dispatch=0")
  }

  func testCombinedStandardOutputAndErrorMustFitMaximumOutputBytes() {
    let stdout = Data(repeating: 0x41, count: 63 * 1_024)
    let stderr = Data(repeating: 0x42, count: 2 * 1_024)

    XCTAssertLessThan(stdout.count, RockchipLDOutputParser.maximumOutputBytes)
    XCTAssertLessThan(stderr.count, RockchipLDOutputParser.maximumOutputBytes)
    XCTAssertEqual(
      RockchipLDOutputParser.parse(stdout: stdout, stderr: stderr),
      .blocked(.outputTooLarge))
  }

  // MARK: - TEST-AC-UX-007-01

  func testTEST_AC_UX_007_01_AccessAdvisorDistinguishesPermissionDriverAndOffline() throws {
    let permission = RockchipLDOutputParser.parse(
      stdout: Data(), stderr: try fixture("permission-denied.stderr.bin"), termination: .exited(1))
    let driver = RockchipLDOutputParser.parse(
      stdout: Data(), stderr: try fixture("driver-unavailable.stderr.bin"), termination: .exited(1))
    let offline = RockchipLDOutputParser.parse(stdout: Data())

    XCTAssertEqual(permission, .blocked(.permissionDenied))
    XCTAssertEqual(driver, .blocked(.driverUnavailable))
    XCTAssertEqual(offline, .blocked(.offline))
    XCTAssertEqual(RockchipDeviceAccessAdvisor.verdict(for: permission), .permissionDenied)
    XCTAssertEqual(RockchipDeviceAccessAdvisor.verdict(for: driver), .driverUnavailable)
    XCTAssertEqual(RockchipDeviceAccessAdvisor.verdict(for: offline), .offlineOrUnauthorized)

    let permissionAdvice = RockchipDeviceAccessAdvisor.advice(for: .permissionDenied)
    XCTAssertEqual(permissionAdvice.responsibility, .systemAdministrator)
    XCTAssertEqual(permissionAdvice.remediation, .reviewDevicePermissionOutsideArkDeck)
    XCTAssertTrue(permissionAdvice.reprobeAvailable)
    let driverAdvice = RockchipDeviceAccessAdvisor.advice(for: .driverUnavailable)
    XCTAssertEqual(driverAdvice.responsibility, .deviceOrToolVendor)
    XCTAssertEqual(driverAdvice.remediation, .repairDriverOutsideArkDeck)
    XCTAssertTrue(driverAdvice.reprobeAvailable)
    print(
      "TEST-AC-UX-007-01 PASS permission=distinct driver=distinct offline=distinct "
        + "sudo=0 helper_install=0 system_rule=0 group_acl=0")
  }

  func testAdapterMaterializesOnlyAbsoluteIdentityBoundLDArgvAndRejectsDriftBeforeLaunch()
    async throws
  {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let executableHash = try sha256(Data(contentsOf: executable))
    let profile = testProfile(executableSHA256: executableHash)
    let launches = LaunchCounter()
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in },
      launchObserver: { _ in launches.increment() })
    let adapter = RockchipDeviceDiscoveryAdapter(profile: profile, executor: executor)

    let acceptedTool = selectedTool(executable: executable, sha256: executableHash)
    let request = try await adapter.processRequest(for: acceptedTool)
    XCTAssertEqual(request.process.executable, executable)
    XCTAssertEqual(request.process.arguments, ["ld"])
    XCTAssertEqual(request.process.environment, [:])
    XCTAssertEqual(request.process.timeout, 5)
    XCTAssertEqual(request.expectedSHA256, executableHash)
    XCTAssertFalse(request.process.arguments.contains("sudo"))
    XCTAssertFalse(request.process.arguments.contains("sh"))

    let driftedTool = selectedTool(
      executable: executable, sha256: String(repeating: "0", count: 64))
    let blocked = await adapter.discover(using: driftedTool)
    XCTAssertEqual(
      blocked.advice.verdict, .toolBlocked(.executableHashMismatch))
    XCTAssertNil(blocked.execution)
    XCTAssertNil(blocked.executableIdentity)
    XCTAssertEqual(launches.value, 0)

    let offlineControl = await adapter.discover(using: acceptedTool)
    XCTAssertEqual(offlineControl.advice.verdict, .offlineOrUnauthorized)
    XCTAssertEqual(offlineControl.diagnostic, .offline)
    XCTAssertEqual(offlineControl.execution?.termination, .exited(0))
    XCTAssertEqual(offlineControl.executableIdentity?.sha256, executableHash)
    XCTAssertEqual(launches.value, 1)
  }

  // MARK: - Helpers

  private func testProfile(executableSHA256: String) -> RockchipDiscoveryIntegrationProfile {
    RockchipDiscoveryIntegrationProfile(
      identifier: "ROCKCHIP-ROCKUSB-DISCOVERY-TEST@1.0.0",
      reportedToolVersion: "test fixture",
      executableSHA256: executableSHA256,
      upstreamCommit: String(repeating: "0", count: 40),
      exactArguments: ["ld"],
      timeout: 5,
      requiresSecurityScopedBookmark: false)
  }

  private func selectedTool(executable: URL, sha256: String) -> RockchipSelectedDiscoveryTool {
    RockchipSelectedDiscoveryTool(
      executableURL: executable,
      pathSource: .userSelectedSecurityScopedBookmark,
      securityScopedBookmark: nil,
      reportedVersion: "test fixture",
      sha256: sha256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: .developerID, quarantinePresent: false))
  }

  private func fixtureRoot() throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "Rockchip", withExtension: nil))
      .appending(path: "Discovery/1.0.0")
  }

  private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureRoot().appending(path: name))
  }

  /// Bundled copies of the canonical `openspec/integrations/rockchip/rockusb-discovery/1.0.0/`
  /// registry files; byte equality with the canonical originals is enforced by
  /// `scripts/rockchip_e0_probe/test_probe.py`, so this suite never reads repository paths.
  private func bundledRegistryURL() throws -> URL {
    try fixtureRoot().appending(path: "registry.yaml")
  }

  private func bundledResourceManifestURL() throws -> URL {
    try fixtureRoot().appending(path: "resources.json")
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
