// Read-only live mode/build observation behind Rockchip target facts.
//
// #992 stopped `TargetStoreRockchipRuntimeFactsPort` from fabricating a
// device mode and flash profile: the durable adoption record cannot support
// them, so it reports "unknown". Reporting unknown is only the first half of
// being honest; this file is the second half — actually measuring them, over
// the same read-only (E0) surfaces the per-action host already drives.
//
// Everything here is E0: `hdc list targets -v`, one allowlisted `param get`
// and `rkdeveloptool ld`. Nothing here transitions a device, and nothing here
// is an admission gate — see `RockchipLiveModeProbing` for that boundary.

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

package enum RockchipLiveModeProbeFailure: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case notObservable(String)

  package var description: String {
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
  func observe(connectKey: String) async throws -> RockchipLiveModeObservation
}

/// Production probe. It reuses the per-action host's command runner, so every
/// child is spawned identity-bound against the same reviewed executables the
/// flash lane uses; it never searches PATH and never falls back to a guess.
package struct FoundationRockchipLiveModeProbe: RockchipLiveModeProbing {
  private let hdcResolver: any RuntimeExecutableResolving
  private let rockchipResolver: any RuntimeExecutableResolving
  private let runner: any RockchipRuntimeCommandRunning

  /// `toolWorkingDirectory` is the same prepared product-owned directory the
  /// per-action host spawns in. `ld` writes the tool's implicit log exactly
  /// like a destructive command does, so a probe that spawned in the caller's
  /// cwd would put back the contamination the flash lane just removed.
  package init(
    hdcResolver: any RuntimeExecutableResolving,
    rockchipResolver: any RuntimeExecutableResolving,
    toolWorkingDirectory: URL
  ) {
    self.init(
      hdcResolver: hdcResolver, rockchipResolver: rockchipResolver,
      runner: FoundationRockchipRuntimeCommandRunner(
        workingDirectory: toolWorkingDirectory))
  }

  init(
    hdcResolver: any RuntimeExecutableResolving,
    rockchipResolver: any RuntimeExecutableResolving,
    runner: any RockchipRuntimeCommandRunning
  ) {
    self.hdcResolver = hdcResolver
    self.rockchipResolver = rockchipResolver
    self.runner = runner
  }

  package func observe(
    connectKey: String
  ) async throws -> RockchipLiveModeObservation {
    // HDC first: it is the only surface that can name *this* target by its
    // connect key. The RockUSB surface below cannot, so it is consulted only
    // once HDC has said the target is not there.
    if try await isConnectedOverHDC(connectKey: connectKey) {
      return RockchipLiveModeObservation(
        deviceMode: "hdc",
        // The mode was observed even when the build readback fails; that is
        // recorded as a known mode with an unknown build, never as a guess.
        buildFingerprint: try? await buildFingerprint(connectKey: connectKey))
    }
    return try await observeRockUSBMode()
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
        // `firmwareVersion` for every versioned DAYU200 profile. Reading any
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

  private func observeRockUSBMode() async throws -> RockchipLiveModeObservation {
    let rockchip = try resolve(rockchipResolver, providerID: "rockchip")
    let receipt = try await read(executable: rockchip, arguments: ["ld"])
    guard
      case .observations(let observations) = RockchipLDOutputParser.parse(
        stdout: receipt.stdout,
        stderr: receipt.stderr,
        termination: .exited(receipt.exitStatus ?? -1))
    else {
      throw RockchipLiveModeProbeFailure.notObservable(
        "rkdeveloptool ld reported no usable RockUSB observation")
    }
    // `ld` carries no serial, so a mode read from it can only be attributed
    // to the bound target when it is the single RockUSB device on the host.
    // Two devices means the observation belongs to nobody in particular, and
    // that is reported as unobservable rather than assigned to this target.
    guard observations.count == 1, let observation = observations.first else {
      throw RockchipLiveModeProbeFailure.notObservable(
        "rkdeveloptool ld reported \(observations.count) RockUSB devices; "
          + "a mode cannot be attributed to the bound target")
    }
    switch observation.mode {
    case .loader:
      return RockchipLiveModeObservation(
        deviceMode: "loader", buildFingerprint: nil)
    case .maskrom:
      return RockchipLiveModeObservation(
        deviceMode: "maskrom", buildFingerprint: nil)
    }
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
