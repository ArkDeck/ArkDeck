import ArkDeckCore
import ArkDeckProcess
import ArkForgeIPC
import Foundation

/// Builds the ArkForge lane from what an operator installed, or explains why
/// there isn't one.
///
/// Absent is the normal state. `arkforged`, a DeviceProfile and the pinned
/// vendor tool all have to be deployed and named before this lane can exist,
/// and a daemon that quietly ran without them would be a daemon that appears
/// able to flash. So every input is required, none is guessed from `PATH` or a
/// default location, and a partial configuration is refused rather than
/// half-applied.
package enum ArkForgeLaneComposition {

  /// Environment keys the LaunchAgent carries, in the same shape as
  /// `ARKDECK_HDC_PATH`: absolute, operator-chosen, checked at startup.
  package enum EnvironmentKey {
    package static let daemonPath = "ARKDECK_ARKFORGED_PATH"
    package static let daemonSHA256 = "ARKDECK_ARKFORGED_SHA256"
    package static let deviceProfilePath = "ARKDECK_ARKFORGE_PROFILE_PATH"
    package static let vendorToolPath = "ARKDECK_RKDEVELOPTOOL_PATH"
  }

  /// Why no lane was composed. Every case names something an operator can fix.
  package enum Absence: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case partiallyConfigured(missing: [String])
    case daemonUnavailable(String)

    package var description: String {
      switch self {
      case .notConfigured:
        return
          "no ArkForge lane: \(EnvironmentKey.daemonPath) is unset, so this daemon performs "
          + "no Rockchip writes. flash.dayu200 refuses before authorization"
      case .partiallyConfigured(let missing):
        return
          "no ArkForge lane: \(missing.joined(separator: ", ")) missing. A partial "
          + "configuration is refused rather than half-applied — a lane composed from some "
          + "of its inputs is one nobody chose"
      case .daemonUnavailable(let detail):
        return "no ArkForge lane: \(detail)"
      }
    }
  }

  /// What a composed lane needs, all of it required.
  package struct Inputs: Sendable, Equatable {
    package let daemonPath: String
    package let daemonSHA256: String
    package let deviceProfilePath: String
    package let vendorToolPath: String

    /// Reads the four keys, or says which are missing.
    ///
    /// The all-or-nothing shape is deliberate. Three of four set is not a lane
    /// with one gap — it is a configuration nobody reviewed, and starting from
    /// it would put an unreviewed combination in front of a destructive write.
    package static func read(
      _ environment: [String: String]
    ) -> Result<Inputs, Absence> {
      let keys = [
        EnvironmentKey.daemonPath, EnvironmentKey.daemonSHA256,
        EnvironmentKey.deviceProfilePath, EnvironmentKey.vendorToolPath,
      ]
      let present = keys.filter { (environment[$0]?.isEmpty == false) }
      if present.isEmpty { return .failure(.notConfigured) }
      let missing = keys.filter { environment[$0]?.isEmpty != false }
      guard missing.isEmpty else { return .failure(.partiallyConfigured(missing: missing)) }
      return .success(
        Inputs(
          daemonPath: environment[EnvironmentKey.daemonPath]!,
          daemonSHA256: environment[EnvironmentKey.daemonSHA256]!,
          deviceProfilePath: environment[EnvironmentKey.deviceProfilePath]!,
          vendorToolPath: environment[EnvironmentKey.vendorToolPath]!))
    }
  }

  /// The argv the daemon is started with.
  ///
  /// The vendor tool's digest is this repository's pin rather than anything the
  /// operator supplied: the toolchain digest is part of the maturity
  /// combination, so letting a caller name it would let a caller publish a
  /// combination nobody reviewed. `--require-release-signing` is likewise not
  /// optional — a build that would accept an unsigned tool on a customer's
  /// machine is not a build worth shipping.
  ///
  /// The pairing secret is absent by construction. It travels on stdin.
  package static func daemonArguments(
    inputs: Inputs, runtimeDirectory: URL, pairingEpoch: UInt64
  ) -> [String] {
    [
      "--runtime-dir", runtimeDirectory.path,
      "--profile", inputs.deviceProfilePath,
      "--pair-from-stdin", String(pairingEpoch),
      "--rkdeveloptool", inputs.vendorToolPath,
      "--rkdeveloptool-sha256", ArkForgeToolchainPin.signedSHA256,
      "--require-release-signing",
    ]
  }

  /// A pairing secret for one daemon lifetime.
  ///
  /// Fresh per launch, and never written anywhere: the epoch rotates with the
  /// process, so an unconsumed permit from a previous run is void rather than
  /// merely old. Reusing one across launches would defeat exactly that.
  package static func freshPairingSecret() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
    return Data(bytes)
  }

  /// Waits for the daemon's controller socket to appear.
  ///
  /// The socket is the readiness signal rather than a line of stdout: it is the
  /// thing the next step actually needs, and parsing a log for readiness is how
  /// a message change becomes an outage.
  package static func awaitControllerSocket(
    runtimeDirectory: URL, deadline: Date,
    sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
  ) async -> String? {
    let socket = runtimeDirectory.appending(path: "controller.sock").path
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socket) { return socket }
      try? await sleep(50_000_000)
    }
    return nil
  }
}
