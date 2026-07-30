// Product-owned Rockchip Runtime composition for GJ-4.
//
// The bundled component is not a PATH/user-selected executable. It is the
// exact nested binary from the reviewed 1.0.0 release tuple. The existing
// destructive Flash profile is intentionally pinned to a different,
// previously hardware-verified binary. Until those identities are reconciled
// by a reviewed product release, Runtime Availability must stay unavailable
// before target facts, plan materialization or E2 capability consumption.

import CryptoKit
import Darwin
import Foundation

public enum BundledRockchipComponent {
  public static let packageID = "arkdeck-rockchip-component-package@1.0.0"
  public static let reportedVersion = "rkdeveloptool ver 1.32"
  public static let bundleRelativePath = "rkdeveloptool"
  public static let signedExecutableSHA256 =
    "9711271d3399b3915bf8ba5beb43ca5321e9eb880a47016d403f1ec358c820bc"

  public static var destructiveProfileExecutableSHA256: String {
    RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
  }
}

public enum BundledRockchipComponentError: Error, Equatable, Sendable,
  CustomStringConvertible
{
  case mainExecutableUnavailable
  case componentMissing
  case nonCanonicalPath
  case notRegularExecutable
  case identityMismatch(expected: String, actual: String)
  case unsupportedProvider(String)

  public var description: String {
    switch self {
    case .mainExecutableUnavailable:
      return "the product executable location is unavailable"
    case .componentMissing:
      return "the bundled rkdeveloptool sibling is missing"
    case .nonCanonicalPath:
      return "the bundled rkdeveloptool path is non-canonical or symlinked"
    case .notRegularExecutable:
      return "the bundled rkdeveloptool is not a regular executable"
    case .identityMismatch(let expected, let actual):
      return "bundled rkdeveloptool identity mismatch (expected \(expected), actual \(actual))"
    case .unsupportedProvider(let providerID):
      return "bundled Rockchip resolver cannot resolve provider \(providerID)"
    }
  }
}

/// Resolves only the fixed sibling embedded in the product. The package-only
/// initializer is a test seam; production callers cannot supply a path.
public struct BundledRockchipExecutableResolver: RuntimeExecutableResolving {
  private let productExecutableURL: URL?
  private let expectedSHA256: String

  public init() {
    productExecutableURL = Bundle.main.executableURL
    expectedSHA256 = BundledRockchipComponent.signedExecutableSHA256
  }

  package init(productExecutableURL: URL?, expectedSHA256: String) {
    self.productExecutableURL = productExecutableURL
    self.expectedSHA256 = expectedSHA256
  }

  public func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard providerID == "rockchip" else {
      throw BundledRockchipComponentError.unsupportedProvider(providerID)
    }
    guard let productExecutableURL else {
      throw BundledRockchipComponentError.mainExecutableUnavailable
    }
    let componentURL = productExecutableURL.deletingLastPathComponent()
      .appendingPathComponent(BundledRockchipComponent.bundleRelativePath)
    guard FileManager.default.fileExists(atPath: componentURL.path) else {
      throw BundledRockchipComponentError.componentMissing
    }
    let standardized = componentURL.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard componentURL.path == standardized.path, standardized.path == canonical.path else {
      throw BundledRockchipComponentError.nonCanonicalPath
    }
    var metadata = stat()
    guard lstat(componentURL.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o111 != 0
    else {
      throw BundledRockchipComponentError.notRegularExecutable
    }
    let data = try Data(contentsOf: componentURL, options: [.mappedIfSafe])
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expectedSHA256 else {
      throw BundledRockchipComponentError.identityMismatch(
        expected: expectedSHA256, actual: actual)
    }
    return ResolvedExecutable(path: componentURL.path, sha256: actual)
  }
}

/// Facts come from the adopted target record and the product-owned component,
/// never from request fields. This makes the target identity and binding
/// revision used for plan admission the same durable facts used by HDC.
public struct TargetStoreRockchipRuntimeFactsPort: RockchipRuntimeFactsPort {
  private let targetStore: RuntimeTargetStore
  private let resolver: any RuntimeExecutableResolving
  private let nowUTC: @Sendable () -> String

  public init(
    targetStore: RuntimeTargetStore,
    resolver: any RuntimeExecutableResolving,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.targetStore = targetStore
    self.resolver = resolver
    self.nowUTC = nowUTC
  }

  public func currentFacts(targetID: String) async throws -> ProviderFacts {
    guard let target = try targetStore.find(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    let component: ResolvedExecutable
    do {
      component = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      throw DeviceProviderError.factsUnavailable(
        "product-owned Rockchip component is unavailable: \(error)")
    }
    return ProviderFacts(
      providerID: "rockchip",
      toolVersion: BundledRockchipComponent.reportedVersion,
      toolSHA256: component.sha256,
      serverFacts: ["componentPackage": BundledRockchipComponent.packageID],
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
      deviceIdentitySHA256: target.stablePhysicalIdentitySHA256,
      executionConnectKey: target.connectKey,
      deviceMode: "hdc",
      buildFingerprint: nil,
      profileID: "dayu200@1",
      collectedAtUTC: nowUTC())
  }
}

/// The Rockchip route is installed in production even while it is
/// unavailable. It validates the exact host-managed action shape and exposes
/// the concrete compatibility blocker through operation.list. It must not
/// fall back to PATH, a bookmark, the HDC dispatcher, or the old whole-plan
/// host (which would consume a second legacy authorization).
public struct BundledRockchipRuntimeDispatcher: RuntimeProcessDispatching {
  private let resolver: any RuntimeExecutableResolving
  private let host: any RockchipRuntimeActionHosting
  private let destructiveExecutableSHA256: String

  public init(resolver: any RuntimeExecutableResolving) {
    self.resolver = resolver
    host = RefusingRockchipRuntimeActionHost(
      reason:
        "the per-action RockUSB host requires descriptor-bound HDC and a product state directory")
    destructiveExecutableSHA256 =
      BundledRockchipComponent.destructiveProfileExecutableSHA256
  }

  public init(
    resolver: any RuntimeExecutableResolving,
    hdcResolver: any RuntimeExecutableResolving,
    stateDirectory: URL
  ) {
    self.resolver = resolver
    host = DurableRockchipRuntimeActionHost(
      executor: FoundationRockchipRuntimeActionExecutor(
        hdcResolver: hdcResolver),
      records: RockchipRuntimeActionRecordStore(
        rootURL: stateDirectory.appendingPathComponent(
          "rockchip-runtime", isDirectory: true)))
    destructiveExecutableSHA256 =
      BundledRockchipComponent.destructiveProfileExecutableSHA256
  }

  init(
    resolver: any RuntimeExecutableResolving,
    host: any RockchipRuntimeActionHosting,
    destructiveExecutableSHA256: String
  ) {
    self.resolver = resolver
    self.host = host
    self.destructiveExecutableSHA256 = destructiveExecutableSHA256
  }

  public func unavailableReason(providerID: String) -> String? {
    guard providerID == "rockchip" else {
      return "bundled Rockchip dispatcher cannot serve provider \(providerID)"
    }
    let component: ResolvedExecutable
    do {
      component = try resolver.resolveExecutable(providerID: providerID)
    } catch {
      return "product-owned Rockchip component is unavailable: \(error)"
    }
    let destructive = destructiveExecutableSHA256
    guard component.sha256 == destructive else {
      return
        "bundled Rockchip component \(BundledRockchipComponent.packageID) has identity "
        + "\(component.sha256), but flash.dayu200@1 is pinned to the hardware-verified "
        + "destructive identity \(destructive); dispatch remains fail-closed"
    }
    return host.unavailableReason()
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .rockchip(let action) = plan.action else {
      throw RuntimeDispatchFailure.failed(
        "bundled Rockchip dispatcher received a non-Rockchip action")
    }
    guard case .hostManaged(let descriptor) = plan.kind else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip runtime actions must use their closed host-managed descriptors")
    }
    if let reason = unavailableReason(providerID: "rockchip") {
      throw RuntimeDispatchFailure.failed(reason)
    }
    let executable: ResolvedExecutable
    do {
      executable = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      throw RuntimeDispatchFailure.failed(
        "product-owned Rockchip component is unavailable: \(error)")
    }
    guard executable.sha256 == destructiveExecutableSHA256 else {
      throw RuntimeDispatchFailure.failed(
        "bundled Rockchip executable identity changed after availability materialization")
    }
    let result = try await host.execute(
      action: action,
      descriptor: descriptor,
      rockchipExecutable: executable)
    guard let recordID = result.summary["recordID"], !recordID.isEmpty else {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "Rockchip host returned no durable job/step receipt")
    }
    return ProviderProcessReceipt(
      exitStatus: 0,
      stdout: result.stdout,
      stderr: result.stderr,
      stdoutTruncated: result.stdoutTruncated,
      durationSeconds: result.subprocesses.reduce(0) {
        $0 + $1.durationSeconds
      },
      hostManagedRecordID: recordID,
      subprocesses: result.subprocesses)
  }
}
