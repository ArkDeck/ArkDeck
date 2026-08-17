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

  /// Everything a composed lane needs that this module cannot reach for
  /// itself: the Rockchip host that performs control actions, and the plan
  /// facts each job's authority is built from.
  struct Dependencies: Sendable {
    let rockchipHost: @Sendable () -> any RockchipRuntimeActionHosting
    let rockchipExecutable: ResolvedExecutable
    let approvedPlan:
      @Sendable (String, String) -> ArkForgeExecutionAuthority.ApprovedPlan

    init(
      rockchipHost: @escaping @Sendable () -> any RockchipRuntimeActionHosting,
      rockchipExecutable: ResolvedExecutable,
      approvedPlan: @escaping @Sendable (String, String)
        -> ArkForgeExecutionAuthority.ApprovedPlan
    ) {
      self.rockchipHost = rockchipHost
      self.rockchipExecutable = rockchipExecutable
      self.approvedPlan = approvedPlan
    }
  }

  /// Starts `arkforged` and returns the lane, or explains why there is none.
  ///
  /// This is the function `main.swift` calls, and the reason it is a function
  /// rather than inline startup code: a lane that is never composed is
  /// indistinguishable, from outside, from a daemon that has no lane
  /// configured — and this project already produced exactly that once, with
  /// every part built and tested and nothing assembling them. A function can
  /// be asserted on; a paragraph inside `main` cannot.
  static func compose(
    environment: [String: String], runtimeDirectory: URL,
    pairingEpoch: UInt64, dependencies: Dependencies,
    launch: @Sendable (ProcessIdentityBoundRequest, Data) async throws -> Void,
    connect: @Sendable (String) throws -> (any ArkForgeFlashSession.Daemon, ArkForgeHelloAck),
    awaitSocket: @Sendable (URL) async -> String?
  ) async -> Result<ArkForgeLaneHost, Absence> {
    let inputs: Inputs
    switch Inputs.read(environment) {
    case .success(let read): inputs = read
    case .failure(let absence): return .failure(absence)
    }

    let secret = freshPairingSecret()
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: URL(filePath: inputs.daemonPath),
        arguments: daemonArguments(
          inputs: inputs, runtimeDirectory: runtimeDirectory, pairingEpoch: pairingEpoch),
        environment: [:], workingDirectory: runtimeDirectory),
      expectedSHA256: inputs.daemonSHA256)

    do {
      try await launch(request, secret)
    } catch {
      return .failure(.daemonUnavailable("arkforged did not start: \(error)"))
    }
    guard let socket = await awaitSocket(runtimeDirectory) else {
      return .failure(
        .daemonUnavailable(
          "arkforged started but never opened its controller socket; it is left running for "
          + "its log rather than killed, because why it did not open is the useful fact"))
    }

    let daemon: any ArkForgeFlashSession.Daemon
    let ack: ArkForgeHelloAck
    do {
      (daemon, ack) = try connect(socket)
    } catch {
      return .failure(.daemonUnavailable("could not open a controller session: \(error)"))
    }
    do {
      // Both standing facts, checked before any job exists. Learning them
      // mid-job is the difference between refusing to start and stopping with
      // a capability already consumed.
      try ArkForgeLaneHost.verifyReadiness(ack)
    } catch {
      return .failure(.daemonUnavailable("\(error)"))
    }

    let host = dependencies.rockchipHost
    let executable = dependencies.rockchipExecutable
    return .success(
      ArkForgeLaneHost(
        connection: .init(socketPath: socket, controllerSessionID: "arkdeck-agentd"),
        makePerformer: { binding, jobID in
          ArkForgeControlPerformer(
            binding: .init(
              connectKey: binding.connectKey,
              stableIdentitySHA256: binding.stableIdentitySHA256,
              usbTopology: binding.usbTopology,
              descriptor: HostManagedProcessDescriptor(
                identifier: "arkforge.managedControl", jobID: jobID,
                stepID: "managed-control", targetID: binding.targetID,
                bindingRevision: binding.bindingRevision,
                connectKey: binding.connectKey,
                expectedIdentitySHA256: binding.stableIdentitySHA256,
                providerExecutableSHA256: executable.sha256,
                actionSHA256: "", executionTuning: nil),
              rockchipExecutable: executable),
            host: host())
        },
        makeClient: { _ in daemon },
        makeAuthority: { jobID, planID in
          ArkForgeExecutionAuthority(
            plan: dependencies.approvedPlan(jobID, planID),
            secret: ArkForgePairingSecret(
              secret: Array(secret), epoch: ArkForgePairingEpoch(pairingEpoch)))
        }))
  }

  /// What `main.swift` calls: composes the lane from the process environment,
  /// performing the real launch, connect and readiness check.
  ///
  /// Takes the dispatcher rather than a host because the host type is internal
  /// to this module — and that is the right shape anyway. Reaching through the
  /// dispatcher means the lane performs control on *the same* host the rest of
  /// the Rockchip lane uses, and a second host would be a second HDC owner.
  package static func composeFromEnvironment(
    runtimeDirectory: URL,
    rockchipDispatcher: BundledRockchipRuntimeDispatcher,
    rockchipExecutable: ResolvedExecutable,
    approvedPlan: @escaping @Sendable (String, String)
      -> ArkForgeExecutionAuthority.ApprovedPlan,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pairingEpoch: UInt64 = UInt64(Date().timeIntervalSince1970)
  ) async -> Result<ArkForgeLaneHost, Absence> {
    let host = rockchipDispatcher.actionHost
    return await compose(
      environment: environment, runtimeDirectory: runtimeDirectory,
      pairingEpoch: pairingEpoch,
      dependencies: .init(
        rockchipHost: { host }, rockchipExecutable: rockchipExecutable,
        approvedPlan: approvedPlan),
      launch: { request, secret in
        _ = try await IdentityBoundDaemonLauncher().launch(request, secret: secret)
      },
      connect: { socket in
        let client = try ArkForgeDaemonClient(socketPath: socket)
        return (client, client.helloAck)
      },
      awaitSocket: { directory in
        // Ten seconds: the measured startup is well under one, and the failure
        // this bounds is a daemon that never opens at all rather than a slow
        // one (the same reasoning as ArkForge's own 5-second tool self-test).
        await awaitControllerSocket(
          runtimeDirectory: directory, deadline: Date().addingTimeInterval(10))
      })
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
