import ArkDeckCore
import ArkDeckProcess
import ArkForgeClient
import ArkForgeProtocol
import Darwin
import Foundation

/// Builds the ArkForge lane from what an operator installed, or explains why
/// there isn't one.
///
/// Absent is the normal state. A validated ArkForge release bundle must be
/// named before this lane can exist; the manifest, rather than three unrelated
/// environment values, selects and binds the daemon and DeviceProfile.
package enum ArkForgeLaneComposition {

  /// Owns the `arkforged` process for exactly one agentd generation.
  ///
  /// Composition used to discard `IdentityBoundDaemonLauncher.Handle` after
  /// startup. launchd could then stop agentd while arkforged remained alive,
  /// reparented to PID 1 and still holding the shared runtime directory and
  /// RockUSB surface. Keeping the stop action beside the composed lane makes
  /// every startup failure and normal daemon shutdown close the same process
  /// generation exactly once.
  package final class DaemonLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopImplementation: (@Sendable () -> Void)?
    private var stopped = false

    package init() {}

    package func install(_ implementation: @escaping @Sendable () -> Void) {
      lock.lock()
      precondition(stopImplementation == nil, "arkforged lifecycle may be installed once")
      if stopped {
        lock.unlock()
        implementation()
        return
      }
      stopImplementation = implementation
      lock.unlock()
    }

    package func stop() {
      lock.lock()
      guard !stopped else {
        lock.unlock()
        return
      }
      stopped = true
      let implementation = stopImplementation
      stopImplementation = nil
      lock.unlock()
      implementation?()
    }

    deinit { stop() }
  }

  /// The exact toolchain identity ArkDeck expects back from the daemon.
  package struct ToolchainIdentity: Sendable, Equatable {
    package let id: String
    package let sha256: String

    package init(id: String, sha256: String) {
      self.id = id
      self.sha256 = sha256.lowercased()
    }
  }

  /// Environment keys the LaunchAgent carries, in the same shape as
  /// `ARKDECK_HDC_PATH`: absolute, operator-chosen, checked at startup.
  package enum EnvironmentKey {
    package static let bundlePath = "ARKDECK_ARKFORGE_BUNDLE_PATH"
    package static let legacyDaemonPath = "ARKDECK_ARKFORGED_PATH"
    package static let legacyDaemonSHA256 = "ARKDECK_ARKFORGED_SHA256"
    package static let legacyDeviceProfilePath = "ARKDECK_ARKFORGE_PROFILE_PATH"
    /// The acceptance campaign this lane is authorized to run, if any.
    ///
    /// Deliberately outside the release-identity input above. The bundle
    /// decides whether a lane exists; this value decides whether the lane may
    /// execute a combination nobody has verified yet, which is a separate and
    /// larger decision. Unset is the normal state: `arkforged` then publishes
    /// `hardwareGated`, materializes assessments only, and no write can reach
    /// a device.
    package static let campaign = "ARKDECK_ARKFORGE_CAMPAIGN"
  }

  /// Why no lane was composed. Every case names something an operator can fix.
  package enum Absence: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case partiallyConfigured(missing: [String])
    case legacyConfiguration
    case mixedConfiguration
    case daemonUnavailable(String)

    package var description: String {
      switch self {
      case .notConfigured:
        return
          "no ArkForge lane: \(EnvironmentKey.bundlePath) is unset, so this daemon performs "
          + "no Rockchip writes. canonical ArkForge Flash refuses before authorization"
      case .partiallyConfigured(let missing):
        return
          "no ArkForge lane: \(missing.joined(separator: ", ")) missing. A partial "
          + "configuration is refused rather than half-applied — a lane composed from some "
          + "of its inputs is one nobody chose"
      case .legacyConfiguration:
        return
          "no ArkForge lane: legacy three-key configuration must be migrated by agentd update "
          + "to one validated \(EnvironmentKey.bundlePath)"
      case .mixedConfiguration:
        return "no ArkForge lane: current bundle and legacy three-key configuration are mixed"
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
    /// Empty when this lane runs no campaign, which is the normal state.
    package let campaign: String

    /// Native RockUSB is part of `arkforged`, so its backend digest is the
    /// exact daemon build the identity-bound launcher verifies.
    package var expectedToolchain: ToolchainIdentity {
      ToolchainIdentity(id: "arkforged-native-rockusb", sha256: daemonSHA256)
    }

    /// Reads one bundle path and derives all release identity from its verified
    /// manifest. Legacy keys are accepted only by the LaunchAgent migration
    /// path; the daemon never assembles them directly.
    package static func read(
      _ environment: [String: String]
    ) -> Result<Inputs, Absence> {
      let legacyKeys = [
        EnvironmentKey.legacyDaemonPath, EnvironmentKey.legacyDaemonSHA256,
        EnvironmentKey.legacyDeviceProfilePath,
      ]
      let legacyPresent = legacyKeys.filter { environment[$0] != nil }
      guard let configured = environment[EnvironmentKey.bundlePath] else {
        return .failure(legacyPresent.isEmpty ? .notConfigured : .legacyConfiguration)
      }
      guard legacyPresent.isEmpty else { return .failure(.mixedConfiguration) }
      guard !configured.isEmpty else {
        return .failure(.partiallyConfigured(missing: [EnvironmentKey.bundlePath]))
      }
      let bundle: ArkForgeReleaseBundle
      do {
        bundle = try ArkForgeReleaseBundleReader.load(
          bundleURL: URL(filePath: configured, directoryHint: .isDirectory))
      } catch {
        return .failure(.daemonUnavailable("ArkForge.bundle is invalid: \(error)"))
      }
      guard let profile = bundle.profileURLs[LaunchAgentArkForgeProfile.dayu200] else {
        return .failure(
          .daemonUnavailable(
            "ArkForge.bundle does not publish \(LaunchAgentArkForgeProfile.dayu200)"))
      }
      let daemonDigest: String
      do {
        daemonDigest = SHA256Hex.string(of: try Data(contentsOf: bundle.daemonURL))
      } catch {
        return .failure(.daemonUnavailable("cannot remeasure arkforged: \(error)"))
      }
      return .success(
        Inputs(
          daemonPath: bundle.daemonURL.path,
          daemonSHA256: daemonDigest,
          deviceProfilePath: profile.path,
          // Absent is not missing. The bundle above is a lane; this is an
          // authorization on top of one, and its absence is the safe state.
          campaign: environment[EnvironmentKey.campaign] ?? ""))
    }
  }

  private enum LaunchAgentArkForgeProfile {
    static let dayu200 = "org.openharmony.dayu200"
  }

  /// The id a DeviceProfile document declares.
  ///
  /// Read from the same file the daemon was handed, rather than configured
  /// separately: `materializePlan` looks a profile up by the id the document
  /// declares, and an operator-supplied id could name a profile the daemon
  /// never loaded. Same file, same field, no room to disagree.
  ///
  /// The shape is `arkforge.device-profile/v1`:
  ///
  /// ```yaml
  /// profile:
  ///   id: org.openharmony.dayu200
  /// ```
  ///
  /// A targeted read rather than a YAML parser, because this needs exactly one
  /// scalar and a parser would be a dependency and a surface. `nil` when the
  /// document does not have that shape, which the caller turns into a refusal
  /// rather than a guess.
  package static func deviceProfileID(inDocument source: String) -> String? {
    var insideProfile = false
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      if text.hasPrefix("#") { continue }
      if text == "profile:" {
        insideProfile = true
        continue
      }
      // Any other column-zero key ends the block; `id` under a different
      // top-level key is a different id.
      if insideProfile, let first = text.first, first != " ", first != "\t", !text.isEmpty {
        insideProfile = false
      }
      guard insideProfile else { continue }
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("id:") else { continue }
      let value = trimmed.dropFirst("id:".count).trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// The argv the daemon is started with.
  ///
  /// Native RockUSB is `arkforged`'s product default, so ArkDeck deliberately
  /// omits a backend-selection flag. That makes default drift observable in the
  /// handshake instead of silently pinning an obsolete migration switch.
  ///
  /// The pairing secret is absent by construction. It travels on stdin.
  package static func daemonArguments(
    inputs: Inputs, runtimeDirectory: URL, pairingEpoch: UInt64
  ) -> [String] {
    var arguments = [
      "--runtime-dir", runtimeDirectory.path,
      "--profile", inputs.deviceProfilePath,
      "--pair-from-stdin", String(pairingEpoch),
    ]
    // Appended only when an operator named one. Without it `arkforged`
    // publishes `hardwareGated` for DAYU200, `materializePlan` answers with an
    // assessment, and this lane refuses at the step rather than writing —
    // which is the correct behaviour for every build nobody authorized a
    // campaign on.
    if !inputs.campaign.isEmpty {
      arguments.append(contentsOf: ["--hardware-campaign", inputs.campaign])
    }
    return arguments
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

  /// A composed lane and the profile id it materializes against.
  ///
  /// Two things rather than one because the engine needs both and they must
  /// come from the same composition: a lane paired with a profile id read from
  /// some other configuration is a lane that could materialize against a
  /// profile the daemon never loaded.
  package struct Composed: Sendable {
    package let deviceProfileID: String
    package let toolchain: ToolchainIdentity
    package let lane: ArkForgeLaneHost
    package let daemonLifecycle: DaemonLifecycle

    package init(
      deviceProfileID: String, toolchain: ToolchainIdentity,
      lane: ArkForgeLaneHost, daemonLifecycle: DaemonLifecycle
    ) {
      self.deviceProfileID = deviceProfileID
      self.toolchain = toolchain
      self.lane = lane
      self.daemonLifecycle = daemonLifecycle
    }
  }

  /// Everything a composed lane needs that this module cannot reach for
  /// itself: the Rockchip host that performs control actions, and the plan
  /// facts each job's authority is built from.
  struct Dependencies: Sendable {
    let rockchipHost: @Sendable () -> any RockchipRuntimeActionHosting
    let providerIdentity: ResolvedExecutable
    let approvedPlan:
      @Sendable (String, String, [UInt8], ArkForgeLaneDeviceBinding)
      -> ArkForgeExecutionAuthority.ApprovedPlan

    init(
      rockchipHost: @escaping @Sendable () -> any RockchipRuntimeActionHosting,
      providerIdentity: ResolvedExecutable,
      approvedPlan: @escaping @Sendable (String, String, [UInt8], ArkForgeLaneDeviceBinding)
        -> ArkForgeExecutionAuthority.ApprovedPlan
    ) {
      self.rockchipHost = rockchipHost
      self.providerIdentity = providerIdentity
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
    daemonLifecycle: DaemonLifecycle = DaemonLifecycle(),
    launch: @Sendable (ProcessIdentityBoundRequest, Data) async throws -> Void,
    connect: @Sendable (String) throws -> (any ArkForgeFlashSession.Daemon, ArkForgeHelloAck),
    awaitSocket: @Sendable (URL) async -> String?
  ) async -> Result<Composed, Absence> {
    let inputs: Inputs
    switch Inputs.read(environment) {
    case .success(let read): inputs = read
    case .failure(let absence): return .failure(absence)
    }

    // Read before the daemon is started, so a profile this side cannot make
    // sense of is a refusal rather than a daemon left running for a lane that
    // could never materialize anything.
    guard let source = try? String(contentsOfFile: inputs.deviceProfilePath, encoding: .utf8)
    else {
      return .failure(
        .daemonUnavailable("cannot read the DeviceProfile at \(inputs.deviceProfilePath)"))
    }
    guard let profileID = deviceProfileID(inDocument: source) else {
      return .failure(
        .daemonUnavailable(
          "the DeviceProfile at \(inputs.deviceProfilePath) declares no profile.id; "
            + "materializePlan addresses a profile by that id, and this lane will not guess one"))
    }
    guard profileID == LaunchAgentArkForgeProfile.dayu200 else {
      return .failure(
        .daemonUnavailable(
          "the bundle manifest selected \(LaunchAgentArkForgeProfile.dayu200), but the "
            + "DeviceProfile declares \(profileID)"))
    }

    let secret = freshPairingSecret()
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: URL(filePath: inputs.daemonPath),
        arguments: daemonArguments(
          inputs: inputs, runtimeDirectory: runtimeDirectory, pairingEpoch: pairingEpoch),
        environment: [:], workingDirectory: runtimeDirectory),
      expectedSHA256: inputs.daemonSHA256)

    // Stale socket files from a previous daemon generation must go before the
    // new one is launched. `awaitSocket` watches for the file to exist — and a
    // leftover file exists instantly, so the controller session connected to
    // the *previous* arkforged (orphaned but still serving its bound inode)
    // while the per-job materializer, connecting later by path, reached the
    // new one. The plan then lived in one daemon and startExecution asked the
    // other, which answered PLAN_NOT_STARTABLE — a split this line makes
    // impossible: with the files gone, the only socket that can appear is the
    // one the daemon launched below binds.
    for name in ["controller.sock", "public.sock"] {
      try? FileManager.default.removeItem(at: runtimeDirectory.appending(path: name))
    }

    do {
      try await launch(request, secret)
    } catch {
      return .failure(.daemonUnavailable("arkforged did not start: \(error)"))
    }
    guard let socket = await awaitSocket(runtimeDirectory) else {
      daemonLifecycle.stop()
      return .failure(
        .daemonUnavailable(
          "arkforged started but never opened its controller socket; the owned process "
          + "generation was stopped before returning the failure"))
    }

    let daemon: any ArkForgeFlashSession.Daemon
    let ack: ArkForgeHelloAck
    do {
      (daemon, ack) = try connect(socket)
    } catch {
      daemonLifecycle.stop()
      return .failure(.daemonUnavailable("could not open a controller session: \(error)"))
    }
    do {
      // Both standing facts, checked before any job exists. Learning them
      // mid-job is the difference between refusing to start and stopping with
      // a capability already consumed.
      try ArkForgeLaneHost.verifyReadiness(
        ack, expectedToolchain: inputs.expectedToolchain)
    } catch {
      daemonLifecycle.stop()
      return .failure(.daemonUnavailable("\(error)"))
    }

    let host = dependencies.rockchipHost
    let providerIdentity = dependencies.providerIdentity
    let loaderObserver = ProductArkForgeLoaderObserver(
      runtimeDirectory: runtimeDirectory)
    return .success(
      Composed(
        deviceProfileID: profileID,
        toolchain: inputs.expectedToolchain,
        lane: ArkForgeLaneHost(
        connection: .init(socketPath: socket, controllerSessionID: "arkdeck-agentd"),
        toolchainSHA256: inputs.expectedToolchain.sha256,
        makePerformer: { binding, jobID in
          // Ingredients, not a descriptor: the performer materializes a valid
          // per-action descriptor through the catalog. The descriptor that
          // used to be fabricated here (`identifier: "arkforge.managedControl"`,
          // `actionSHA256: ""`) matched no action's identifier and no action's
          // digest, so the validating host refused every control action this
          // lane ever attempted — the flash stalled at its first step with
          // both sides waiting on the other.
          ArkForgeControlPerformer(
            binding: .init(
              jobID: jobID,
              targetID: binding.targetID,
              bindingRevision: binding.bindingRevision,
              connectKey: binding.connectKey,
              stableIdentitySHA256: binding.stableIdentitySHA256,
              usbTopology: binding.usbTopology,
              providerIdentity: providerIdentity),
            host: host(),
            loaderObserver: loaderObserver)
        },
        makeClient: { _ in daemon },
        // A second connection, deliberately. Materialization streams ~731 MB
        // and the controller session is the one the job's event stream runs
        // on; sharing it would hold that stream for the length of an import.
        makeMaterializer: { socket in
          try ArkForgeControllerClient(
            socketPath: socket,
            timeoutSeconds: ArkForgeControllerClient.materializationTimeoutSeconds)
        },
        makeAuthority: { jobID, planID, planDigest, deviceBinding in
          ArkForgeExecutionAuthority(
            plan: dependencies.approvedPlan(jobID, planID, planDigest, deviceBinding),
            secret: ArkForgePairingSecret(
              secret: Array(secret), epoch: ArkForgePairingEpoch(pairingEpoch)))
        }),
        daemonLifecycle: daemonLifecycle))
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
    rockchipDispatcher: ArkForgeNativeRockchipControlDispatcher,
    providerIdentity: ResolvedExecutable,
    approvedPlan: @escaping @Sendable (String, String, [UInt8], ArkForgeLaneDeviceBinding)
      -> ArkForgeExecutionAuthority.ApprovedPlan,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pairingEpoch: UInt64 = UInt64(Date().timeIntervalSince1970)
  ) async -> Result<Composed, Absence> {
    let host = rockchipDispatcher.actionHost
    let daemonLifecycle = DaemonLifecycle()
    return await compose(
      environment: environment, runtimeDirectory: runtimeDirectory,
      pairingEpoch: pairingEpoch,
      dependencies: .init(
        rockchipHost: { host }, providerIdentity: providerIdentity,
        approvedPlan: approvedPlan),
      daemonLifecycle: daemonLifecycle,
      launch: { request, secret in
        let handle = try await IdentityBoundDaemonLauncher().launch(request, secret: secret)
        daemonLifecycle.install {
          stopDaemonProcessGroup(handle)
        }
      },
      connect: { socket in
        let client = try ArkForgeControllerClient(socketPath: socket)
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

  /// Stops and reaps the exact child generation without leaving a PID-1
  /// orphan. SIGTERM gets a bounded grace period; SIGKILL is confined to the
  /// launcher's dedicated process group and is used only when that exact child
  /// has not exited. The grace period is deliberately shorter than launchd's
  /// service-exit budget: waiting longer lets launchd kill agentd before it can
  /// reach the group cleanup, which is precisely how the orphan is created.
  private static func stopDaemonProcessGroup(
    _ handle: IdentityBoundDaemonLauncher.Handle
  ) {
    handle.terminate()
    let gracefulDeadline = Date().addingTimeInterval(0.5)
    var status: Int32 = 0
    while Date() < gracefulDeadline {
      let result = waitpid(handle.processIdentifier, &status, WNOHANG)
      if result == handle.processIdentifier { return }
      if result < 0 && errno == ECHILD {
        if !processGroupExists(handle.processIdentifier) { return }
        usleep(50_000)
        continue
      }
      if result < 0 && errno != EINTR { return }
      usleep(50_000)
    }

    guard kill(-handle.processIdentifier, SIGKILL) == 0 || errno != ESRCH else { return }
    let forcedDeadline = Date().addingTimeInterval(0.5)
    while Date() < forcedDeadline {
      let result = waitpid(handle.processIdentifier, &status, WNOHANG)
      if result == handle.processIdentifier { return }
      if result < 0 && errno == ECHILD {
        if !processGroupExists(handle.processIdentifier) { return }
        usleep(50_000)
        continue
      }
      if result < 0 && errno != EINTR { return }
      usleep(50_000)
    }
  }

  private static func processGroupExists(_ leader: pid_t) -> Bool {
    if kill(-leader, 0) == 0 { return true }
    return errno == EPERM
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
