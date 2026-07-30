import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class RockchipRuntimeCompositionContractTests: XCTestCase {
  private struct HDCFacts: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "b", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: 1,
        deviceIdentitySHA256: String(repeating: "a", count: 64),
        executionConnectKey: "device-1", deviceMode: "hdc",
        buildFingerprint: nil,
        profileID: "openharmony-standard@1",
        collectedAtUTC: "2026-07-31T00:00:00Z")
    }
  }

  private actor DispatchLog {
    private var providers: [String] = []

    func append(_ provider: String) {
      providers.append(provider)
    }

    func snapshot() -> [String] {
      providers
    }
  }

  private struct RecordingDispatcher: RuntimeProcessDispatching {
    let provider: String
    let log: DispatchLog
    let reason: String?

    func unavailableReason(providerID: String) -> String? { reason }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      await log.append(provider)
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(provider.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0)
    }
  }

  func testRouterSelectsOnlyFromTypedAction() async throws {
    let log = DispatchLog()
    let router = RuntimeProcessDispatcherRouter(
      hdc: RecordingDispatcher(provider: "hdc", log: log, reason: nil),
      rockchip: RecordingDispatcher(
        provider: "rockchip", log: log, reason: "rockchip unavailable"))
    let hdcProvider = HDCObservationProviderAdapter(factsPort: HDCFacts())
    let context = ProviderExecutionContext(
      jobID: "job-router", stepID: "route", targetID: "TGT-ROUTER",
      bindingRevision: 1, connectKey: "device-1",
      expectedIdentitySHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-31T00:00:00Z")
    let hdcAction = TypedProviderAction.hdc(
      .queryProperty(HDCAllowlistedProperty.productModel))
    let hdcPlan = try hdcProvider.lower(action: hdcAction, context: context)
    _ = try await router.dispatch(hdcPlan)

    let rockchipProvider = RockchipFlashProviderAdapter(availability: .available)
    let rockchipPlan = try rockchipProvider.lower(
      action: .rockchip(.enterLoader(connectKey: "device-1")), context: context)
    _ = try await router.dispatch(rockchipPlan)

    let recordedProviders = await log.snapshot()
    XCTAssertEqual(recordedProviders, ["hdc", "rockchip"])
    XCTAssertNil(router.unavailableReason(providerID: "hdc"))
    XCTAssertEqual(
      router.unavailableReason(providerID: "rockchip"), "rockchip unavailable")
    XCTAssertNotNil(router.unavailableReason(providerID: "adb"))
  }

  func testBundledResolverAcceptsOnlyFixedSiblingAndExactIdentity() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let product = root.appendingPathComponent("arkdeck-agentd")
    let component = root.appendingPathComponent("rkdeveloptool")
    try Data("product".utf8).write(to: product)
    try Data("component".utf8).write(to: component)
    XCTAssertEqual(chmod(component.path, 0o700), 0)
    let componentSHA = SHA256.hash(data: Data("component".utf8))
      .map { String(format: "%02x", $0) }.joined()

    let resolver = BundledRockchipExecutableResolver(
      productExecutableURL: product, expectedSHA256: componentSHA)
    XCTAssertEqual(
      try resolver.resolveExecutable(providerID: "rockchip"),
      ResolvedExecutable(path: component.path, sha256: componentSHA))
    XCTAssertThrowsError(try resolver.resolveExecutable(providerID: "hdc"))

    let wrongIdentity = BundledRockchipExecutableResolver(
      productExecutableURL: product, expectedSHA256: String(repeating: "f", count: 64))
    XCTAssertThrowsError(try wrongIdentity.resolveExecutable(providerID: "rockchip")) { error in
      guard case BundledRockchipComponentError.identityMismatch = error else {
        return XCTFail("expected identityMismatch, got \(error)")
      }
    }

    try FileManager.default.removeItem(at: component)
    try FileManager.default.createSymbolicLink(
      at: component, withDestinationURL: product)
    let symlinkResolver = BundledRockchipExecutableResolver(
      productExecutableURL: product,
      expectedSHA256: SHA256.hash(data: Data("product".utf8))
        .map { String(format: "%02x", $0) }.joined())
    XCTAssertThrowsError(try symlinkResolver.resolveExecutable(providerID: "rockchip")) { error in
      XCTAssertEqual(error as? BundledRockchipComponentError, .nonCanonicalPath)
    }
  }

  func testFactsUseAdoptedIdentityBindingAndProductComponent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let targetStore = try RuntimeTargetStore(
      directoryURL: root.appendingPathComponent("targets", isDirectory: true))
    let identity = String(repeating: "a", count: 64)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: identity, connectKey: "device-1",
      toolVersion: "3.2.0f", nowUTC: "2026-07-31T00:00:00Z"
    ).record
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: BundledRockchipComponent.signedExecutableSHA256)
    let factsPort = TargetStoreRockchipRuntimeFactsPort(
      targetStore: targetStore,
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      nowUTC: { "2026-07-31T01:02:03Z" })

    let facts = try await factsPort.currentFacts(targetID: adopted.targetID)
    XCTAssertEqual(facts.providerID, "rockchip")
    XCTAssertEqual(facts.targetID, adopted.targetID)
    XCTAssertEqual(facts.bindingRevision, adopted.bindingRevision)
    XCTAssertEqual(facts.deviceIdentitySHA256, identity)
    XCTAssertEqual(facts.executionConnectKey, "device-1")
    XCTAssertEqual(facts.toolSHA256, component.sha256)
    XCTAssertEqual(
      facts.serverFacts["componentPackage"], BundledRockchipComponent.packageID)
    XCTAssertEqual(facts.profileID, "dayu200@1")
  }

  func testProductionRockchipRoutePublishesExactCompatibilityBlocker() async throws {
    let resolver = FixedExecutableResolver(
      table: [
        "rockchip": ResolvedExecutable(
          path: "/product/Contents/MacOS/rkdeveloptool",
          sha256: BundledRockchipComponent.signedExecutableSHA256)
      ])
    let dispatcher = BundledRockchipRuntimeDispatcher(resolver: resolver)
    let reason = try XCTUnwrap(dispatcher.unavailableReason(providerID: "rockchip"))
    XCTAssertTrue(reason.contains(BundledRockchipComponent.packageID), reason)
    XCTAssertTrue(
      reason.contains(BundledRockchipComponent.signedExecutableSHA256), reason)
    XCTAssertTrue(
      reason.contains(BundledRockchipComponent.destructiveProfileExecutableSHA256), reason)

    let provider = RockchipFlashProviderAdapter(availability: .available)
    let plan = try provider.lower(
      action: .rockchip(.enterLoader(connectKey: "device-1")),
      context: ProviderExecutionContext(
        jobID: "job-1", stepID: "enter-loader", targetID: "TGT-1",
        bindingRevision: 1, nowUTC: "2026-07-31T00:00:00Z"))
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("identity drift must dispatch zero processes")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("expected definite pre-dispatch failure, got \(failure)")
      }
      XCTAssertEqual(detail, reason)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "arkdeck-rockchip-runtime-\(UUID().uuidString.lowercased())",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }
}
