// Read-only live mode/build observation behind Rockchip target facts.
//
// #992 stopped `TargetStoreRockchipRuntimeFactsPort` from fabricating a
// device mode and flash profile: the durable adoption record cannot support
// them, so it reports "unknown". Reporting unknown is only the first half of
// being honest; this file is the second half — actually measuring them, over
// the same read-only (E0) surfaces the per-action host already drives.
//
// Everything here is E0: IOKit identity, `hdc list targets -v`, one allowlisted
// `param get` and ArkForge `discoverDevices`. Nothing here transitions a device, and
// nothing here is an admission gate — see `RockchipLiveModeProbing` for that
// boundary.

import ArkDeckOpenHarmony
import Foundation

/// One read-only observation of the bound target's current mode and build.
package struct RockchipLiveModeObservation: Sendable, Equatable {
  /// `hdc`, `loader` or `maskrom`. Absence is not encoded here: a probe that
  /// cannot see the device throws, and the facts port turns that into
  /// `absent`.
  package let deviceMode: String
  /// Exact `const.ohos.fullname` readback. Only the HDC surface exposes a
  /// build at all, so the RockUSB modes leave this `nil` rather than carrying
  /// an inferred or stale value.
  package let buildFingerprint: String?

  package init(deviceMode: String, buildFingerprint: String?) {
    self.deviceMode = deviceMode
    self.buildFingerprint = buildFingerprint
  }
}

public enum RockchipLiveModeProbeFailure: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case notObservable(String)

  public var description: String {
    switch self {
    case .notObservable(let detail):
      return "the bound Rockchip target is not observable: \(detail)"
    }
  }
}

/// The optional live seam behind Rockchip target facts.
///
/// Deliberately *not* an admission gate. Facts are the portrait taken before
/// admission; the fail-closed authority gates are the engine's fresh readback
/// and reservation at the consume point. So a probe that cannot reach the
/// device throws, the facts port encodes that as `deviceMode: "absent"`, and
/// device-absent planOnly/draft keeps working with no device attached.
package protocol RockchipLiveModeProbing: Sendable {
  func observe(
    connectKey: String,
    stableIdentitySHA256: String
  ) async throws -> RockchipLiveModeObservation
}

/// Production probe. It reuses the per-action host's command runner, so every
/// child is spawned identity-bound against the same reviewed executables the
/// flash lane uses; it never searches PATH and never falls back to a guess.
package struct FoundationRockchipLiveModeProbe: RockchipLiveModeProbing {
  private let hdcResolver: any RuntimeExecutableResolving
  private let runner: any RockchipRuntimeCommandRunning
  private let loaderObserver: any ArkForgeLoaderObserving

  /// `toolWorkingDirectory` is the same prepared product-owned directory the
  /// per-action host uses for its remaining HDC reads. Loader mode is observed
  /// separately through ArkForge's public read-only socket and IOKit.
  package init(
    hdcResolver: any RuntimeExecutableResolving,
    rockchipResolver _: any RuntimeExecutableResolving,
    toolWorkingDirectory: URL
  ) {
    self.init(
      hdcResolver: hdcResolver,
      runner: FoundationRockchipRuntimeCommandRunner(
        workingDirectory: toolWorkingDirectory),
      loaderObserver: ProductArkForgeLoaderObserver(
        runtimeDirectory: toolWorkingDirectory.deletingLastPathComponent()
          .appending(path: "arkforge", directoryHint: .isDirectory)))
  }

  init(
    hdcResolver: any RuntimeExecutableResolving,
    runner: any RockchipRuntimeCommandRunning,
    loaderObserver: any ArkForgeLoaderObserving
  ) {
    self.hdcResolver = hdcResolver
    self.runner = runner
    self.loaderObserver = loaderObserver
  }

  package func observe(
    connectKey: String,
    stableIdentitySHA256: String
  ) async throws -> RockchipLiveModeObservation {
    // HDC first: it names this target by its connect key. Once HDC says that
    // personality is absent, RockUSB must independently match the target's
    // stable IOKit identity and ArkForge topology before it may name the mode.
    if try await isConnectedOverHDC(connectKey: connectKey) {
      return RockchipLiveModeObservation(
        deviceMode: "hdc",
        // The mode was observed even when the build readback fails; that is
        // recorded as a known mode with an unknown build, never as a guess.
        buildFingerprint: try? await buildFingerprint(connectKey: connectKey))
    }
    return try await observeRockUSBMode(
      stableIdentitySHA256: stableIdentitySHA256)
  }

  private func isConnectedOverHDC(connectKey: String) async throws -> Bool {
    let hdc = try resolve(hdcResolver, providerID: "hdc")
    let receipt = try await read(
      executable: hdc, arguments: ["list", "targets", "-v"])
    switch HDCObservationSemanticParser.parseTargetList(
      stdout: receipt.stdout,
      profile: .openHarmony320Family,
      toolVersion: "3.2.0f",
      truncated: receipt.stdoutTruncated)
    {
    case .parsed(let list):
      return list.targets.filter {
        $0.connectKey == connectKey && $0.state == "Connected"
      }.count == 1
    case .empty:
      return false
    case .unsupportedVersion(let version):
      throw RockchipLiveModeProbeFailure.notObservable(
        "HDC target parser does not support \(version)")
    case .invalidEncoding:
      throw RockchipLiveModeProbeFailure.notObservable(
        "HDC target list is not UTF-8")
    case .truncated:
      throw RockchipLiveModeProbeFailure.notObservable(
        "HDC target list exceeded its byte budget")
    case .malformed(let reason):
      throw RockchipLiveModeProbeFailure.notObservable(
        "HDC target list is malformed: \(reason)")
    }
  }

  private func buildFingerprint(connectKey: String) async throws -> String {
    let hdc = try resolve(hdcResolver, providerID: "hdc")
    let receipt = try await read(
      executable: hdc,
      arguments: [
        "-t", connectKey, "shell", "param", "get",
        // The same param the post-flash verifier pins against a published
        // profile's `runtimeBuildVersion`, which is also the profile's
        // `firmwareVersion` for the singleton DAYU200 profile. Reading any
        // other property would produce a fingerprint that cannot match a
        // published profile on a real device.
        HDCAllowlistedProperty.fullBuildVersion.rawValue,
      ])
    guard let text = String(data: receipt.stdout, encoding: .utf8) else {
      throw RockchipLiveModeProbeFailure.notObservable(
        "build property readback is not UTF-8")
    }
    let value = HDCObservationProviderAdapter.propertyValue(
      fromParamGetOutput: text,
      requestedKey: HDCAllowlistedProperty.fullBuildVersion.rawValue)
    guard !value.isEmpty, value.count <= 400 else {
      throw RockchipLiveModeProbeFailure.notObservable(
        "build property readback is empty or oversized")
    }
    return value
  }

  private func observeRockUSBMode(
    stableIdentitySHA256: String
  ) async throws -> RockchipLiveModeObservation {
    do {
      _ = try loaderObserver.observeLoader(
        stableIdentitySHA256: stableIdentitySHA256,
        expectedUSBTopology: nil,
        requestID: "live-mode-\(UUID().uuidString.lowercased())")
    } catch {
      throw RockchipLiveModeProbeFailure.notObservable(
        "ArkForge dual-source Loader observation failed: \(error)")
    }
    return RockchipLiveModeObservation(
      deviceMode: "loader", buildFingerprint: nil)
  }

  private func resolve(
    _ resolver: any RuntimeExecutableResolving, providerID: String
  ) throws -> ResolvedExecutable {
    do {
      return try resolver.resolveExecutable(providerID: providerID)
    } catch {
      throw RockchipLiveModeProbeFailure.notObservable(
        "\(providerID) executable is unavailable to the facts probe: \(error)")
    }
  }

  private func read(
    executable: ResolvedExecutable, arguments: [String]
  ) async throws -> ProviderSubprocessReceipt {
    let receipt: ProviderSubprocessReceipt
    do {
      receipt = try await runner.run(
        executable: executable,
        arguments: arguments,
        timeoutSeconds: 15,
        outputByteBudget: 64 * 1024,
        criticalNonInterruptible: false)
    } catch {
      throw RockchipLiveModeProbeFailure.notObservable(
        "read-only probe command did not complete: \(error)")
    }
    guard receipt.exitStatus == 0 else {
      throw RockchipLiveModeProbeFailure.notObservable(
        "read-only probe command exited \(receipt.exitStatus.map(String.init) ?? "unknown")")
    }
    return receipt
  }
}
