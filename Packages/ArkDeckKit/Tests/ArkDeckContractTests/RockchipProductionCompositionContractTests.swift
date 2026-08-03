import ArkDeckProcess
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// TASK-AIN-003R / AIN-COMP-001 contract coverage. The production admission
/// composition must hand the declarative discovery hash gate an adapter whose
/// profile carries the same `pinnedProduction` executable hash pin that
/// `RockchipAuthorizationFacts` asserts. The negative leg injects the exact
/// pre-remediation defect (the read-only E0 profile behind the
/// production-declared tool) and proves it stays fail closed with the existing
/// typed path-source error vocabulary and zero process spawn. The suite never
/// launches a process and never touches a device.
final class RockchipProductionCompositionContractTests: XCTestCase {
  /// Independent test-side anchor for the destructive production tool pin.
  /// Deliberately a literal rather than a read of the production constant:
  /// if the constant drifts, this suite goes red on its own.
  private static let independentlyPinnedProductionSHA256 =
    "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"

  private final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  // MARK: - AIN-COMP-001 positive leg

  func testProductionCompositionAdapterCarriesTheFactsAssertedProductionHashPin()
    async throws
  {
    let literal = Self.independentlyPinnedProductionSHA256
    let toolWorkingDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    let adapter = RockchipProductionDiscoveryComposition.admissionDiscoveryAdapter(
      toolWorkingDirectory: toolWorkingDirectory)

    let request = try await adapter.processRequest(for: productionDeclaredTool())
    XCTAssertEqual(
      request.expectedSHA256, literal,
      "the composed admission adapter must pin the destructive production tool hash")
    XCTAssertEqual(
      RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256, literal,
      "the constant RockchipAuthorizationFacts asserts must equal the independent literal")
    XCTAssertEqual(request.process.arguments, ["ld"])
    XCTAssertEqual(request.process.environment, [:])
    XCTAssertEqual(request.process.workingDirectory, toolWorkingDirectory)
    print(
      "TEST-AIN-COMP-001 PASS leg=positive composition_pin=facts_pin=independent_literal "
        + "declaration_gate=accepted device_dispatch=0")
  }

  // MARK: - AIN-COMP-001 negative leg (real-fault injection, TR-002R precedent)

  func testReadOnlyProfileInjectionStaysFailClosedWithoutSpawningAProcess() async throws {
    let launches = LaunchCounter()
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in },
      launchObserver: { _ in launches.increment() })
    // Real fault: the pre-remediation composition wiring — the read-only E0
    // discovery profile injected behind the production-declared tool.
    let defectiveAdapter = RockchipDeviceDiscoveryAdapter(
      profile: .pinnedReadOnlyDiscovery, executor: executor)
    let tool = productionDeclaredTool()

    do {
      _ = try await defectiveAdapter.processRequest(for: tool)
      XCTFail("the typed path-source gate must reject the read-only profile for this tool")
    } catch {
      XCTAssertEqual(error as? RockchipToolValidationError, .pathSourceNotUserSelected)
    }

    let port = RockchipDiscoveryToolDeviceFactPort(
      sessionID: "S-AIN-003R", jobID: "J-AIN-003R", targetID: "T-AIN-003R",
      observationSequence: 1, adapter: defectiveAdapter, tool: tool,
      clock: RockchipContinuousAdmissionClock())
    do {
      _ = try await port.observeToolAndDevice()
      XCTFail("tool/device observation must be unavailable when the hash gate rejects")
    } catch {
      XCTAssertEqual(
        error as? RockchipAuthorizationFactError, .toolOrDeviceObservationUnavailable)
    }
    XCTAssertEqual(
      launches.value, 0, "a blocked declaration gate must never spawn a process")
    print(
      "TEST-AIN-COMP-001 PASS leg=negative real_fault=readOnlyProfileInjection "
        + "gate=pathSourceNotUserSelected admission=toolOrDeviceObservationUnavailable "
        + "spawn=0 device_dispatch=0")
  }

  func testProductToolRuntimeOwnsEmptyConfigAndLogOutsideTheCallerWorkingDirectory()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-rockchip-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let runtime = try RockchipProductToolRuntimeDirectory.prepare(root: root)
    let config = runtime.appending(path: RockchipProductToolRuntimeDirectory.configurationFileName)
    let log = runtime.appending(
      path: RockchipProductToolRuntimeDirectory.logDirectoryName, directoryHint: .isDirectory)

    XCTAssertEqual(
      runtime,
      root.appending(
        path: RockchipProductToolRuntimeDirectory.directoryName,
        directoryHint: .isDirectory).standardizedFileURL)
    XCTAssertEqual(try Data(contentsOf: config), Data())
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(try permissions(of: runtime), 0o700)
    XCTAssertEqual(try permissions(of: log), 0o700)
    XCTAssertEqual(try permissions(of: config), 0o600)
  }

  func testProductToolRuntimeRejectsAConfigThatCouldChangeToolSemantics() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-rockchip-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runtime = try RockchipProductToolRuntimeDirectory.prepare(root: root)
    let config = runtime.appending(path: RockchipProductToolRuntimeDirectory.configurationFileName)
    try Data("unexpected-option=true\n".utf8).write(to: config)

    XCTAssertThrowsError(try RockchipProductToolRuntimeDirectory.prepare(root: root)) { error in
      guard let flashError = error as? RockchipFlashExecutionError,
        case .productionConfigurationUnavailable(let reason) = flashError
      else { return XCTFail("expected productionConfigurationUnavailable, got \(error)") }
      XCTAssertEqual(
        reason, "Rockchip tool config must be an empty owner-only regular file")
    }
  }

  // MARK: - Helpers

  private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }

  /// A tool declared exactly in the production shape
  /// (`RockchipProductExecutionSettings.load()`): installed ordinary
  /// bookmark, `pinnedProduction` reported version and
  /// executable hash, non-quarantined platform trust.
  private func productionDeclaredTool() -> RockchipSelectedDiscoveryTool {
    RockchipSelectedDiscoveryTool(
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      pathSource: .installedOrdinaryBookmark,
      bookmarkData: Data([0x01]),
      reportedVersion: RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion,
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: .adHoc, quarantinePresent: false))
  }
}
