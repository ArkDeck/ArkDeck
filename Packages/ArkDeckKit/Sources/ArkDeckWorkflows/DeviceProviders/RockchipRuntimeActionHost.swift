// Product-owned per-action managed-control host for ArkForge Flash.
//
// RuntimeJobEngine owns capability admission and the outer write-ahead
// intent. This host does not construct another authorization/session model:
// it executes only the already-materialized closed action, binds every child
// to a reviewed executable identity, and writes a job/step-correlated receipt.

import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

struct RockchipRuntimeActionExecutionResult: Sendable {
  let summary: [String: String]
  let stdout: Data
  let stderr: Data
  let stdoutTruncated: Bool
  let subprocesses: [ProviderSubprocessReceipt]
}

protocol RockchipRuntimeActionExecuting: Sendable {
  func unavailableReason() -> String?
  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    actionDirectory: URL
  ) async throws -> RockchipRuntimeActionExecutionResult
  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    actionDirectory: URL,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> RockchipRuntimeActionExecutionResult
}

extension RockchipRuntimeActionExecuting {
  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    actionDirectory: URL,
    progress _: @escaping RuntimeProcessProgressHandler
  ) async throws -> RockchipRuntimeActionExecutionResult {
    try await execute(
      action: action, descriptor: descriptor,
      providerExecutable: providerExecutable, actionDirectory: actionDirectory)
  }
}

protocol RockchipRuntimeActionHosting: Sendable {
  func unavailableReason() -> String?
  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable
  ) async throws -> RockchipRuntimeActionExecutionResult
  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> RockchipRuntimeActionExecutionResult
}

extension RockchipRuntimeActionHosting {
  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    progress _: @escaping RuntimeProcessProgressHandler
  ) async throws -> RockchipRuntimeActionExecutionResult {
    try await execute(
      action: action, descriptor: descriptor,
      providerExecutable: providerExecutable)
  }
}

struct RefusingRockchipRuntimeActionHost: RockchipRuntimeActionHosting {
  let reason: String

  func unavailableReason() -> String? { reason }

  func execute(
    action _: RockchipProviderAction,
    descriptor _: HostManagedProcessDescriptor,
    providerExecutable _: ResolvedExecutable
  ) async throws -> RockchipRuntimeActionExecutionResult {
    throw RuntimeDispatchFailure.failed(reason)
  }
}

protocol RockchipRuntimeCommandRunning: Sendable {
  func run(
    executable: ResolvedExecutable,
    arguments: [String],
    timeoutSeconds: Int?,
    outputByteBudget: Int,
    criticalNonInterruptible: Bool
  ) async throws -> ProviderSubprocessReceipt
  func run(
    executable: ResolvedExecutable,
    arguments: [String],
    timeoutSeconds: Int?,
    outputByteBudget: Int,
    criticalNonInterruptible: Bool,
    onOutput: @escaping ProcessOutputHandler
  ) async throws -> ProviderSubprocessReceipt
}

extension RockchipRuntimeCommandRunning {
  func run(
    executable: ResolvedExecutable,
    arguments: [String],
    timeoutSeconds: Int?,
    outputByteBudget: Int,
    criticalNonInterruptible: Bool,
    onOutput _: @escaping ProcessOutputHandler
  ) async throws -> ProviderSubprocessReceipt {
    try await run(
      executable: executable, arguments: arguments,
      timeoutSeconds: timeoutSeconds, outputByteBudget: outputByteBudget,
      criticalNonInterruptible: criticalNonInterruptible)
  }
}

struct FoundationRockchipRuntimeCommandRunner: RockchipRuntimeCommandRunning {
  /// Product-owned current directory bound to every child spawned here.
  ///
  /// Binding every remaining HDC child to product-owned Runtime state keeps
  /// command execution independent of the daemon's launch directory and
  /// prevents runtime output from landing in a source checkout.
  ///
  /// This is deliberately not optional: the runner is the only spawn point of
  /// the engine lane, so a composition that cannot name product-owned state
  /// must refuse rather than silently inherit a cwd.
  ///
  /// The hdc transitions this runner also serves tolerate the bound directory
  /// — their argv carries no relative path and hdc writes nothing to cwd
  /// (verified: `hdc list targets -v` from a scoped directory exits 0 and
  /// leaves it empty).
  let workingDirectory: URL

  func run(
    executable: ResolvedExecutable,
    arguments: [String],
    timeoutSeconds: Int?,
    outputByteBudget: Int,
    criticalNonInterruptible: Bool
  ) async throws -> ProviderSubprocessReceipt {
    try await run(
      executable: executable, arguments: arguments,
      timeoutSeconds: timeoutSeconds, outputByteBudget: outputByteBudget,
      criticalNonInterruptible: criticalNonInterruptible,
      onOutput: { _ in })
  }

  func run(
    executable: ResolvedExecutable,
    arguments: [String],
    timeoutSeconds: Int?,
    outputByteBudget: Int,
    criticalNonInterruptible: Bool,
    onOutput: @escaping ProcessOutputHandler
  ) async throws -> ProviderSubprocessReceipt {
    let operation: @Sendable () async throws -> ProviderSubprocessReceipt = {
      let request = ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: URL(filePath: executable.path),
          arguments: arguments,
          // This runner serves the remaining HDC transitions. The spawn base
          // allowlist drops an inherited HDC port, so it is named explicitly.
          environment: HDCServerEndpointSelector.inheritedPortChildEnvironment(),
          workingDirectory: workingDirectory,
          timeout: timeoutSeconds.map(TimeInterval.init)),
        expectedSHA256: executable.sha256)
      let result: ProcessIdentityBoundExecutionResult
      do {
        result = try await FoundationProcessExecutor().executeIdentityBound(
          request, captureLimit: outputByteBudget, onOutput: onOutput)
      } catch let error as ProcessExecutionError {
        // All thrown ProcessExecutionError cases happen before a child has
        // been observed as spawned. They are definite zero-dispatch refusals.
        throw RuntimeDispatchFailure.failed("dispatch refused: \(error)")
      } catch {
        throw RuntimeDispatchFailure.outcomeUnknown(
          "dispatch outcome unobservable: \(error)")
      }
      switch result.execution.termination {
      case .exited(let status):
        return ProviderSubprocessReceipt(
          exitStatus: status,
          stdout: result.execution.stdout.data,
          stderr: result.execution.stderr.data,
          stdoutTruncated: result.execution.stdout.wasTruncated,
          durationSeconds: 0)
      case .timedOut:
        throw RuntimeDispatchFailure.outcomeUnknown(
          "process timed out before completion")
      case .cancelled:
        throw RuntimeDispatchFailure.outcomeUnknown(
          "process cancelled mid-flight")
      case .signalled(let signal):
        throw RuntimeDispatchFailure.outcomeUnknown(
          RockchipHostProcessDiagnostics.signalDeath(signal))
      case .waitFailed(let code), .unrecognizedWaitStatus(let code):
        throw RuntimeDispatchFailure.outcomeUnknown(
          "process wait status unresolved (\(code))")
      }
    }
    if criticalNonInterruptible {
      // A parent cancellation is observed only after one native write reaches
      // its semantic boundary. No later partition is started after that.
      return try await Task.detached(operation: operation).value
    }
    return try await operation()
  }
}

struct RockchipRuntimeLoaderIdentity: Sendable, Equatable {
  let serialDigestSHA256: String
  let topology: String
}

struct RockchipRuntimeHDCIdentity: Sendable, Equatable {
  let connectKey: String
  let serialDigestSHA256: String
  let topology: String
}

/// Short-lived observations shared only between adjacent logical receipts of
/// one managed-control sequence. The receipt store still records every typed
/// action separately; this cache merely prevents those actions from asking the
/// same physical USB/HDC question again after a stronger postcondition has
/// already answered it.
private actor RockchipRuntimeObservationReuseCache {
  struct LoaderKey: Hashable, Sendable {
    let jobID: String
    let targetID: String
    let bindingRevision: Int
    let stableIdentitySHA256: String
    let controlAttempt: String
  }

  struct BoundHDCKey: Hashable, Sendable {
    let jobID: String
    let targetID: String
    let bindingRevision: Int
    let stableIdentitySHA256: String
    let previousIdentitySHA256: String
    let usbTopology: String
  }

  private struct LoaderRecord: Sendable {
    let identity: RockchipRuntimeLoaderIdentity
    let recordedAtNanoseconds: UInt64
  }

  private struct BoundHDCRecord: Sendable {
    let identity: RockchipRuntimeHDCIdentity
    let recordedAtNanoseconds: UInt64
  }

  private static let maximumAgeNanoseconds: UInt64 = 120 * 1_000_000_000
  private var loaders: [LoaderKey: LoaderRecord] = [:]
  private var boundHDC: [BoundHDCKey: BoundHDCRecord] = [:]

  func rememberLoader(_ identity: RockchipRuntimeLoaderIdentity, for key: LoaderKey) {
    purgeExpired()
    loaders[key] = LoaderRecord(
      identity: identity,
      recordedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
  }

  func loader(for key: LoaderKey, consume: Bool) -> RockchipRuntimeLoaderIdentity? {
    purgeExpired()
    guard let record = loaders[key] else { return nil }
    if consume { loaders.removeValue(forKey: key) }
    return record.identity
  }

  func rememberBoundHDC(_ identity: RockchipRuntimeHDCIdentity, for key: BoundHDCKey) {
    purgeExpired()
    boundHDC[key] = BoundHDCRecord(
      identity: identity,
      recordedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
  }

  func takeBoundHDC(for key: BoundHDCKey) -> RockchipRuntimeHDCIdentity? {
    purgeExpired()
    return boundHDC.removeValue(forKey: key)?.identity
  }

  private func purgeExpired() {
    let now = DispatchTime.now().uptimeNanoseconds
    loaders = loaders.filter {
      now >= $0.value.recordedAtNanoseconds
        && now - $0.value.recordedAtNanoseconds <= Self.maximumAgeNanoseconds
    }
    boundHDC = boundHDC.filter {
      now >= $0.value.recordedAtNanoseconds
        && now - $0.value.recordedAtNanoseconds <= Self.maximumAgeNanoseconds
    }
  }
}

protocol RockchipRuntimeUSBProbing: Sendable {
  func singleLoader(
    stableIdentitySHA256: String
  ) throws -> RockchipRuntimeLoaderIdentity
  func singleHDCNormal(
    stableIdentitySHA256: String
  ) throws -> RockchipRuntimeLoaderIdentity
  func singleHDCNormal(
    usbTopology: String
  ) throws -> RockchipRuntimeHDCIdentity
}

extension RockchipRuntimeUSBProbing {
  func singleHDCNormal(usbTopology _: String) throws -> RockchipRuntimeHDCIdentity {
    throw RockchipFlashExecutionError.admissionRejected(
      "topology-bound HDC observation is unavailable")
  }
}

struct ProductRockchipRuntimeUSBProbe: RockchipRuntimeUSBProbing {
  private let probe = RockchipProductUSBProbe()

  func singleLoader(
    stableIdentitySHA256: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    let identity = try probe.singleLoader(
      stableIdentitySHA256: stableIdentitySHA256)
    return RockchipRuntimeLoaderIdentity(
      serialDigestSHA256: SHA256Hex.string(of: Data(identity.serial.utf8)),
      topology: identity.topology)
  }

  func singleHDCNormal(
    stableIdentitySHA256: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    let identity = try probe.singleConnected(
      stableIdentitySHA256: stableIdentitySHA256)
    return RockchipRuntimeLoaderIdentity(
      serialDigestSHA256: SHA256Hex.string(of: Data(identity.serial.utf8)),
      topology: identity.topology)
  }

  func singleHDCNormal(
    usbTopology: String
  ) throws -> RockchipRuntimeHDCIdentity {
    let identity = try probe.singleConnected(selector: usbTopology)
    return RockchipRuntimeHDCIdentity(
      connectKey: identity.serial,
      serialDigestSHA256: SHA256Hex.string(of: Data(identity.serial.utf8)),
      topology: identity.topology)
  }
}

struct FoundationRockchipRuntimeActionExecutor: RockchipRuntimeActionExecuting {
  private let hdcResolver: any RuntimeExecutableResolving
  private let runner: any RockchipRuntimeCommandRunning
  private let usbProbe: any RockchipRuntimeUSBProbing
  private let loaderObserver: any ArkForgeLoaderObserving
  /// The board carrying the facts of the bundle in hand. A seam like `stage`,
  /// so composition tests keep proving every branch without a real archive;
  /// production reads the bytes, which is the only way to know the bundle is
  /// the one this plan was built for.
  private let enterLoaderReadbackTimeoutSeconds: Int
  private let postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore?
  private let nowUTC: @Sendable () -> String
  private let observationReuseCache: RockchipRuntimeObservationReuseCache

  /// `runner` has no default on purpose. The production runner cannot be
  /// constructed without a product-owned working directory, and this executor
  /// is not the layer that knows one; the composition root supplies it.
  init(
    hdcResolver: any RuntimeExecutableResolving,
    runner: any RockchipRuntimeCommandRunning,
    usbProbe: any RockchipRuntimeUSBProbing = ProductRockchipRuntimeUSBProbe(),
    loaderObserver: any ArkForgeLoaderObserving = RefusingArkForgeLoaderObserver(
      reason: "no ArkForge Loader observation source was composed"),
    enterLoaderReadbackTimeoutSeconds: Int = 45,
    postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore? = nil,
    nowUTC: @escaping @Sendable () -> String = {
      ISO8601Timestamps.string(from: Date())
    }
  ) {
    self.hdcResolver = hdcResolver
    self.runner = runner
    self.usbProbe = usbProbe
    self.loaderObserver = loaderObserver
    self.enterLoaderReadbackTimeoutSeconds = enterLoaderReadbackTimeoutSeconds
    self.postFlashHDCBindingStore = postFlashHDCBindingStore
    self.nowUTC = nowUTC
    self.observationReuseCache = RockchipRuntimeObservationReuseCache()
  }

  func unavailableReason() -> String? {
    do {
      _ = try hdcResolver.resolveExecutable(providerID: "hdc")
      return nil
    } catch {
      return "descriptor-bound HDC executable is unavailable to the Rockchip host: \(error)"
    }
  }

  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    actionDirectory: URL
  ) async throws -> RockchipRuntimeActionExecutionResult {
    try await execute(
      action: action, descriptor: descriptor,
      providerExecutable: providerExecutable, actionDirectory: actionDirectory,
      progress: { _ in })
  }

  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    actionDirectory: URL,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> RockchipRuntimeActionExecutionResult {
    switch action {
    case .enterLoader(let connectKey):
      // A fresh exact Loader readback is already the postcondition of this
      // step. Do not send the normal-mode HDC transition command to a target
      // that is demonstrably no longer on HDC: it cannot add evidence and a
      // missing HDC receipt would otherwise park an already-flashable device
      // as outcome-unknown. USB identity alone is insufficient, so pair it
      // with ArkForge's independently enumerated observation before treating the step as
      // complete. If either readback is absent, retain the normal-mode path
      // below and its existing fail-closed semantics.
      if let loader = try? exactLoaderIdentity(
        stableIdentitySHA256: descriptor.expectedIdentitySHA256
      ) {
        let confirmed = try confirmLoader(
          loader,
          stableIdentitySHA256: descriptor.expectedIdentitySHA256,
          expectedUSBTopology: loader.topology,
          requestID: "\(descriptor.jobID)-\(descriptor.stepID)-already-loader")
        await rememberLoaderObservation(confirmed, descriptor: descriptor, actionIndex: 1)
        return result(
          summary: [
            "transition": "already-loader",
            "transitionEvidence": "exact-bound-loader-readback",
            "loaderIdentitySha256": confirmed.serialDigestSHA256,
            "usbTopology": confirmed.topology,
          ],
          receipts: [])
      }

      let hdc = try resolveHDC()
      var hdcReceipt: ProviderSubprocessReceipt?
      var unresolvedHDCFailure: RuntimeDispatchFailure?
      do {
        let receipt = try await runner.run(
          executable: hdc,
          arguments: RockchipHDCIntegrationProfile.enterLoaderArguments(
            connectKey: connectKey),
          timeoutSeconds: 20,
          outputByteBudget: 64 * 1024,
          criticalNonInterruptible: false)
        hdcReceipt = receipt
        let clean =
          receipt.exitStatus == 0 && !receipt.stdoutTruncated && receipt.stderr.isEmpty
        if !clean {
          unresolvedHDCFailure = .outcomeUnknown(
            "HDC reboot-loader returned no clean semantic receipt")
        }
      } catch let failure as RuntimeDispatchFailure {
        // A failed runner dispatch is known to be pre-spawn and therefore has
        // zero device effect. Every other thrown runner result is unresolved
        // until the exact Loader readback below settles it.
        if case .failed = failure { throw failure }
        unresolvedHDCFailure = failure
      } catch {
        unresolvedHDCFailure = .outcomeUnknown(
          "HDC reboot-loader dispatch outcome was unobservable: \(error)")
      }

      do {
        let loader = try await waitForLoader(
          stableIdentitySHA256: descriptor.expectedIdentitySHA256,
          timeoutSeconds: enterLoaderReadbackTimeoutSeconds,
          pollIntervalMilliseconds: 1_000,
          requestID: "\(descriptor.jobID)-\(descriptor.stepID)-post-transition")
        await rememberLoaderObservation(loader, descriptor: descriptor, actionIndex: 1)
        let receipts = hdcReceipt.map { [$0] } ?? []
        return result(
          summary: [
            "transition": "normal-to-loader",
            "transitionEvidence": "exact-bound-loader-readback",
            "loaderIdentitySha256": loader.serialDigestSHA256,
            "usbTopology": loader.topology,
          ],
          receipts: receipts)
      } catch {
        // Both exits below carry the HDC receipt summary. Without it, a failed
        // transition said only that the Loader was not observed, and the
        // actual cause — a non-zero exit, a killed child, an stderr line —
        // survived nowhere but a macOS crash report.
        let evidence = Self.transitionEvidenceSummary(
          receipt: hdcReceipt, failure: unresolvedHDCFailure)
        if let normal = try? exactHDCNormalIdentity(connectKey: connectKey) {
          let diagnostic: RockchipFlashRuntimeDiagnostic =
            unresolvedHDCFailure == nil
            ? .enterLoaderCommandCleanLoaderNotObserved
            : .enterLoaderHDCNoCleanReceipt
          throw RuntimeDispatchFailure.confirmedNotExecutedWithDiagnostic(
            "exact bound HDC-normal USB readback proves the Loader transition did not complete "
              + "at topology \(normal.topology) \(evidence)",
            diagnostic: diagnostic)
        }
        if let unresolvedHDCFailure { throw unresolvedHDCFailure }
        // Even exit 0 is not the semantic boundary for a command whose
        // success disconnects its transport. Without the exact bound Loader
        // postcondition, the mutation remains unknown and cannot be replayed.
        throw RuntimeDispatchFailure.outcomeUnknown(
          "HDC reboot-loader exited but the exact bound Loader was not observed \(evidence)")
      }

    case .observeHDCNormalUSB(let connectKey):
      let identity = try exactHDCNormalIdentity(connectKey: connectKey)
      return result(
        summary: [
          "hdcNormalIdentitySha256": identity.serialDigestSHA256,
          "usbState": "hdc-normal",
          "usbTopology": identity.topology,
        ],
        receipts: [])

    case .waitForHDCDisconnect(let connectKey):
      if let loader = await reusedLoaderObservation(
        descriptor: descriptor, actionIndex: 2, consume: false)
      {
        return result(
          summary: [
            "hdcState": "disconnected",
            "transitionEvidence": "exact-bound-loader-readback",
            "loaderIdentitySha256": loader.serialDigestSHA256,
            "usbTopology": loader.topology,
          ],
          receipts: [])
      }
      let receipts = try await waitForHDC(
        connectKey: connectKey, expectedConnected: false,
        timeoutSeconds: 15,
        commandTimeoutSeconds: 15)
      return result(
        summary: ["hdcState": "disconnected"], receipts: receipts)

    case .waitForLoader(let stableIdentitySHA256):
      if let identity = await reusedLoaderObservation(
        descriptor: descriptor, actionIndex: 3, consume: false),
        identity.serialDigestSHA256 == stableIdentitySHA256
      {
        return result(
          summary: [
            "loaderIdentitySha256": identity.serialDigestSHA256,
            "usbTopology": identity.topology,
            "observationReuse": "enter-loader-postcondition",
          ],
          receipts: [])
      }
      let identity = try await waitForLoader(
        stableIdentitySHA256: stableIdentitySHA256,
        timeoutSeconds: 45,
        pollIntervalMilliseconds: 1_000,
        requestID: "\(descriptor.jobID)-\(descriptor.stepID)-wait-loader")
      await rememberLoaderObservation(identity, descriptor: descriptor, actionIndex: 3)
      return result(
        summary: [
          "loaderIdentitySha256": identity.serialDigestSHA256,
          "usbTopology": identity.topology,
        ],
        receipts: [])

    case .rebindLoader(let stableIdentitySHA256):
      if let identity = await reusedLoaderObservation(
        descriptor: descriptor, actionIndex: 4, consume: true),
        identity.serialDigestSHA256 == stableIdentitySHA256
      {
        return result(
          summary: [
            "loaderIdentitySha256": identity.serialDigestSHA256,
            "usbTopology": identity.topology,
            "bindingRevision": String(descriptor.bindingRevision),
            "observationReuse": "exact-bound-loader-readback",
          ],
          receipts: [])
      }
      let identity = try exactLoaderIdentity(
        stableIdentitySHA256: stableIdentitySHA256)
      let confirmed = try confirmLoader(
        identity,
        stableIdentitySHA256: stableIdentitySHA256,
        expectedUSBTopology: identity.topology,
        requestID: "\(descriptor.jobID)-\(descriptor.stepID)-rebind-loader")
      return result(
        summary: [
          "loaderIdentitySha256": confirmed.serialDigestSHA256,
          "usbTopology": confirmed.topology,
          "bindingRevision": String(descriptor.bindingRevision),
        ],
        receipts: [])

    // Native ArkForge owns the write, verification and reset as one delegated
    // plan. This legacy action remains decodable for old journals, but must
    // never launch the current provider identity as an argv-compatible CLI.
    case .rebootToNormal:
      throw RuntimeDispatchFailure.failed(
        "legacy direct Rockchip reset is retired; native ArkForge owns device reset")

    case .waitForHDCReconnect(let connectKey):
      let receipts = try await waitForHDC(
        connectKey: connectKey, expectedConnected: true, timeoutSeconds: 120,
        commandTimeoutSeconds: 15)
      return result(
        summary: ["hdcState": "connected"], receipts: receipts)

    case .waitForBoundHDCReconnect(let expectation):
      // The bound reconnect this action waits for is the first boot after a
      // complete overwrite: userdata was just erased, so the device is
      // initializing filesystems and running first-boot setup before hdcd
      // comes up. Measured 2026-08-18, twice: the 120-second deadline expired
      // mid-first-boot, and so did a 300-second one — the board answered on
      // its known key minutes after the window closed, with the whole job
      // already classified outcome-unknown. Ten minutes bounds a hung boot
      // without calling this board's real first boot missing.
      let (identity, receipts) = try await waitForBoundHDC(
        expectation: expectation,
        timeoutSeconds: 600,
        commandTimeoutSeconds: 15)
      await observationReuseCache.rememberBoundHDC(
        identity,
        for: Self.boundHDCReuseKey(
          descriptor: descriptor, expectation: expectation))
      return result(
        summary: [
          "hdcState": "connected",
          "hdcIdentitySha256": identity.serialDigestSHA256,
          "usbTopology": identity.topology,
        ],
        receipts: receipts)

    // verifyBuild was dispatched here. It read model/build back over a bare
    // connect key and stamped the receipt `exact-published-profile` — a
    // post-flash verification claim resting on no identity proof. The bound arm
    // below is the whole action: prove the device first, then read it.
    case .verifyBoundBuild(
      let expectation, let expectedProductModel, let expectedBuildVersion):
      guard !expectedProductModel.isEmpty, !expectedBuildVersion.isEmpty,
        let postFlashHDCBindingStore
      else {
        throw RuntimeDispatchFailure.failed(
          "post-flash binding verification is not fully configured")
      }
      // This wait is the first boot after a complete overwrite: the plan's
      // reset is arkforged's native RockUSB action, so the very next thing the authority is
      // asked for is this verification — against a device that is still
      // initializing its freshly erased userdata before hdcd comes up. The
      // read-only command timeout (15 s) belongs to the parameter reads once
      // the device is present, not to the boot in front of them: with it, the
      // window closed mid-first-boot on every full flash while the board
      // answered on its known key minutes later (measured 2026-08-18, three
      // runs — including two where a larger budget was put on the reconnect
      // action this plan never dispatches). Ten minutes bounds a hung boot
      // without calling this board's real first boot missing.
      let reuseKey = Self.boundHDCReuseKey(
        descriptor: descriptor, expectation: expectation)
      let cachedIdentity = await observationReuseCache.takeBoundHDC(for: reuseKey)
      let identity: RockchipRuntimeHDCIdentity
      let observationReceipts: [ProviderSubprocessReceipt]
      if let cachedIdentity,
        let revalidated = try? revalidateBoundHDC(
          cachedIdentity, expectation: expectation)
      {
        identity = revalidated
        observationReceipts = []
      } else {
        (identity, observationReceipts) = try await waitForBoundHDC(
          expectation: expectation,
          timeoutSeconds: 600,
          commandTimeoutSeconds: 15)
      }
      let hdc = try resolveHDC()
      let propertiesReceipt = try await run(
        executable: hdc,
        arguments: [
          "-t", identity.connectKey, "shell",
          RockchipHDCIntegrationProfile.postFlashBuildPropertiesCommand,
        ],
        timeoutSeconds: 15,
        budget: 64 * 1024)
      let propertyKeys = [
        HDCAllowlistedProperty.fullBuildVersion.rawValue,
        HDCAllowlistedProperty.productModel.rawValue,
      ]
      let properties = try properties(propertiesReceipt, orderedKeys: propertyKeys)
      let version = properties[HDCAllowlistedProperty.fullBuildVersion.rawValue] ?? ""
      let model = properties[HDCAllowlistedProperty.productModel.rawValue] ?? ""
      guard model == expectedProductModel else {
        throw RuntimeDispatchFailure.failed(
          "post-flash model readback does not match the published profile")
      }
      guard version == expectedBuildVersion else {
        throw RuntimeDispatchFailure.failed(
          "post-flash build readback does not match the published profile")
      }
      do {
        _ = try postFlashHDCBindingStore.publish(
          RockchipPostFlashHDCBinding(
            targetID: descriptor.targetID,
            bindingRevision: descriptor.bindingRevision,
            stableLoaderIdentitySHA256: descriptor.expectedIdentitySHA256,
            previousHDCIdentitySHA256: expectation.previousIdentitySHA256,
            hdcIdentitySHA256: identity.serialDigestSHA256,
            hdcConnectKey: identity.connectKey,
            usbTopology: identity.topology,
            productModel: model,
            buildVersion: version,
            jobID: descriptor.jobID,
            establishedAtUTC: nowUTC()),
          expectedPreviousHDCIdentitySHA256: expectation.previousIdentitySHA256)
      } catch {
        throw RuntimeDispatchFailure.failed(
          "verified post-flash HDC binding could not be persisted: \(error)")
      }
      return result(
        summary: [
          "model": model,
          "firmware": version,
          "hdcIdentitySha256": identity.serialDigestSHA256,
          "usbTopology": identity.topology,
          "verification": "exact-published-profile-and-bound-hdc",
        ],
        receipts: observationReceipts + [propertiesReceipt])

    case .capturePostFlashDiagnostics(let connectKey, let request):
      let hdc = try resolveHDC()
      let receipt = try await run(
        executable: hdc,
        arguments: ["-t", connectKey, "shell", "hilog", "-x"] + request.filters,
        timeoutSeconds: request.durationSeconds + 15,
        budget: request.byteBudget)
      guard !receipt.stdout.isEmpty else {
        throw RuntimeDispatchFailure.failed(
          "post-flash HiLog capture returned no bytes")
      }
      return RockchipRuntimeActionExecutionResult(
        summary: [
          "byteCount": String(receipt.stdout.count),
          "debugRuntime": "ready",
          "verification": "full",
        ],
        stdout: receipt.stdout,
        stderr: receipt.stderr,
        stdoutTruncated: receipt.stdoutTruncated,
        subprocesses: [receipt])
    }
  }

  private func waitForHDC(
    connectKey: String,
    expectedConnected: Bool,
    timeoutSeconds: Int,
    commandTimeoutSeconds: Int
  ) async throws -> [ProviderSubprocessReceipt] {
    let hdc = try resolveHDC()
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    var receipts: [ProviderSubprocessReceipt] = []
    var lastMalformedReason: String?
    while ContinuousClock.now < deadline {
      let receipt = try await run(
        executable: hdc,
        arguments: ["list", "targets", "-v"],
        timeoutSeconds: commandTimeoutSeconds,
        budget: 64 * 1024)
      receipts.append(receipt)
      switch HDCObservationSemanticParser.parseTargetList(
        stdout: receipt.stdout,
        profile: .openHarmony320Family,
        toolVersion: "3.2.0f",
        truncated: receipt.stdoutTruncated)
      {
      case .parsed(let list):
        let matches = list.targets.filter {
          $0.connectKey == connectKey && $0.state == "Connected"
        }
        if expectedConnected ? matches.count == 1 : matches.isEmpty {
          return receipts
        }
      case .unsupportedVersion(let version):
        throw RuntimeDispatchFailure.failed(
          "HDC target parser does not support \(version)")
      case .invalidEncoding:
        throw RuntimeDispatchFailure.failed(
          "HDC target list is not UTF-8")
      case .truncated:
        throw RuntimeDispatchFailure.failed(
          "HDC target list exceeded its byte budget")
      case .empty:
        break
      case .malformed(let reason):
        // A DAYU200 crossing a reboot passes through USB enumeration states
        // in which the hdc server briefly prints a target line outside the
        // registered 5-column family. On 2026-08-04 the wait after a fully
        // verified flash+reboot died on one such read — and the device went
        // on to boot fine, so the single malformed snapshot proved nothing
        // about the target. One bad read is a moment in time; only a
        // deadline's worth of them is a verdict. Record it, keep polling,
        // and let the deadline stay the fail-closed boundary.
        lastMalformedReason = reason
      }
      try await Task.sleep(for: .seconds(1))
    }
    let malformedSuffix =
      lastMalformedReason.map {
        "; last malformed target list read: \($0)"
      } ?? ""
    throw RuntimeDispatchFailure.failed(
      (expectedConnected
        ? "descriptor-bound HDC target did not reconnect before the deadline"
        : "descriptor-bound HDC target did not disconnect before the deadline")
        + malformedSuffix)
  }

  /// Resolves the normal-mode HDC personality through the owner-only USB
  /// topology carried by the durable DAYU200 binding. A firmware image may
  /// legitimately change the HDC serial, so the old connect key is evidence
  /// of the previous route, not the only acceptable postcondition. Exactly
  /// one registered HDC USB identity at the expected topology and exactly one
  /// matching Connected HDC row are required on every successful return.
  private func waitForBoundHDC(
    expectation: RockchipHDCReconnectExpectation,
    timeoutSeconds: Int,
    commandTimeoutSeconds: Int
  ) async throws -> (RockchipRuntimeHDCIdentity, [ProviderSubprocessReceipt]) {
    let previousDigest = SHA256Hex.string(of: Data(expectation.previousConnectKey.utf8))
    guard previousDigest == expectation.previousIdentitySHA256,
      !expectation.usbTopology.isEmpty,
      expectation.usbTopology.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw RuntimeDispatchFailure.failed(
        "post-flash HDC binding expectation is malformed")
    }
    let hdc = try resolveHDC()
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    var receipts: [ProviderSubprocessReceipt] = []
    var lastMalformedReason: String?
    while ContinuousClock.now < deadline {
      let receipt = try await run(
        executable: hdc,
        arguments: ["list", "targets", "-v"],
        timeoutSeconds: commandTimeoutSeconds,
        budget: 64 * 1024)
      receipts.append(receipt)
      switch HDCObservationSemanticParser.parseTargetList(
        stdout: receipt.stdout,
        profile: .openHarmony320Family,
        toolVersion: "3.2.0f",
        truncated: receipt.stdoutTruncated)
      {
      case .parsed(let list):
        // Two routes prove the same bound device, and either suffices when
        // there is exactly one candidate. The recorded topology was meant to
        // be the stable half while firmware may rotate the serial — but the
        // measured board re-enumerates its locationID across the first boot
        // after a flash (17956864 → 18087936 on 2026-08-18, third distinct
        // value this bench has recorded), so a topology-only pin waits out
        // its whole deadline on a device that is present, single, and
        // answering on its known connect key. The known key is the other
        // route: `previousIdentitySHA256` is its alias digest by definition.
        // Both drifting at once stays a refusal — that is a replugged or
        // swapped board, which is a rebind, not a reconnect.
        let byTopology = try? usbProbe.singleHDCNormal(
          usbTopology: expectation.usbTopology)
        let byKnownAlias =
          byTopology != nil
          ? nil
          : (try? usbProbe.singleHDCNormal(
            stableIdentitySHA256: expectation.previousIdentitySHA256))
            .flatMap { try? usbProbe.singleHDCNormal(usbTopology: $0.topology) }
        if let identity = byTopology ?? byKnownAlias {
          let observedDigest = SHA256Hex.string(of: Data(identity.connectKey.utf8))
          guard identity.serialDigestSHA256 == observedDigest,
            identity.topology == expectation.usbTopology
              || identity.serialDigestSHA256 == expectation.previousIdentitySHA256
          else {
            throw RuntimeDispatchFailure.failed(
              "topology-bound HDC USB identity is internally inconsistent")
          }
          guard
            list.targets.filter({
              $0.connectKey == identity.connectKey && $0.state == "Connected"
            }).count == 1
          else { break }
          return (identity, receipts)
        }
      case .unsupportedVersion(let version):
        throw RuntimeDispatchFailure.failed(
          "HDC target parser does not support \(version)")
      case .invalidEncoding:
        throw RuntimeDispatchFailure.failed("HDC target list is not UTF-8")
      case .truncated:
        throw RuntimeDispatchFailure.failed("HDC target list exceeded its byte budget")
      case .empty:
        break
      case .malformed(let reason):
        lastMalformedReason = reason
      }
      try await Task.sleep(for: .seconds(1))
    }
    let malformedSuffix =
      lastMalformedReason.map {
        "; last malformed target list read: \($0)"
      } ?? ""
    throw RuntimeDispatchFailure.failed(
      "topology-bound HDC target did not reconnect before the deadline"
        + malformedSuffix)
  }

  /// What the Loader transition command actually did, in one bounded clause.
  /// It carries the exit status, the runner failure (which names a terminating
  /// signal when there was one) and a truncated stderr prefix. Device identity
  /// stays out of it: the serial-derived fields already have their own
  /// digest/topology shapes elsewhere in this message.
  static func transitionEvidenceSummary(
    receipt: ProviderSubprocessReceipt?,
    failure: RuntimeDispatchFailure?
  ) -> String {
    var parts: [String] = []
    if let receipt {
      parts.append("hdcExitStatus=\(receipt.exitStatus.map(String.init) ?? "unknown")")
      if receipt.stdoutTruncated { parts.append("hdcOutputTruncated=true") }
      if !receipt.stderr.isEmpty {
        parts.append("hdcStderr=\"\(Self.evidenceText(receipt.stderr))\"")
      }
    } else {
      parts.append("hdcExitStatus=none")
    }
    if let failure {
      parts.append("hdcFailure=\(Self.failureDetail(failure))")
    }
    return "[\(parts.joined(separator: " "))]"
  }

  private static let maximumEvidenceStderrBytes = 200

  private static func evidenceText(_ data: Data) -> String {
    let prefix = data.prefix(maximumEvidenceStderrBytes)
    guard let text = String(data: prefix, encoding: .utf8) else {
      return "<\(data.count) non-UTF-8 bytes>"
    }
    let collapsed = text.unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) || $0 == "\"" ? " " : Character($0)
    }
    let squeezed = String(collapsed).split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    return data.count > maximumEvidenceStderrBytes ? squeezed + "…" : squeezed
  }

  private static func failureDetail(_ failure: RuntimeDispatchFailure) -> String {
    switch failure {
    case .outcomeUnknown(let detail), .confirmedNotExecuted(let detail),
      .confirmedNotExecutedWithDiagnostic(let detail, _), .failed(let detail):
      return detail
    }
  }

  private func exactHDCNormalIdentity(
    connectKey: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    let identity = SHA256Hex.string(of: Data(connectKey.utf8))
    return try usbProbe.singleHDCNormal(stableIdentitySHA256: identity)
  }

  /// Rechecks a just-observed post-flash route through IOKit before reusing
  /// it for the targeted property query. This removes a second slow HDC target
  /// list without turning a historical connect key into current evidence.
  private func revalidateBoundHDC(
    _ cached: RockchipRuntimeHDCIdentity,
    expectation: RockchipHDCReconnectExpectation
  ) throws -> RockchipRuntimeHDCIdentity {
    let previousDigest = SHA256Hex.string(of: Data(expectation.previousConnectKey.utf8))
    guard previousDigest == expectation.previousIdentitySHA256 else {
      throw RuntimeDispatchFailure.failed(
        "post-flash HDC binding expectation is malformed")
    }
    let byTopology = try? usbProbe.singleHDCNormal(usbTopology: cached.topology)
    let byIdentity =
      byTopology != nil
      ? nil
      : (try? usbProbe.singleHDCNormal(
        stableIdentitySHA256: cached.serialDigestSHA256))
        .flatMap { try? usbProbe.singleHDCNormal(usbTopology: $0.topology) }
    guard let observed = byTopology ?? byIdentity,
      observed == cached,
      observed.serialDigestSHA256
        == SHA256Hex.string(of: Data(observed.connectKey.utf8)),
      observed.topology == expectation.usbTopology
        || observed.serialDigestSHA256 == expectation.previousIdentitySHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "cached post-flash HDC route did not pass a fresh exact IOKit readback")
    }
    return observed
  }

  private func rememberLoaderObservation(
    _ identity: RockchipRuntimeLoaderIdentity,
    descriptor: HostManagedProcessDescriptor,
    actionIndex: Int
  ) async {
    guard let key = Self.loaderReuseKey(
      descriptor: descriptor, actionIndex: actionIndex)
    else { return }
    await observationReuseCache.rememberLoader(identity, for: key)
  }

  private func reusedLoaderObservation(
    descriptor: HostManagedProcessDescriptor,
    actionIndex: Int,
    consume: Bool
  ) async -> RockchipRuntimeLoaderIdentity? {
    guard let key = Self.loaderReuseKey(
      descriptor: descriptor, actionIndex: actionIndex)
    else { return nil }
    return await observationReuseCache.loader(for: key, consume: consume)
  }

  /// Accepts only the step-id shape emitted by `ArkForgeControlPerformer`.
  /// A similarly named plan action or a later control request therefore cannot
  /// inherit an observation just because its job and target happen to match.
  private static func loaderReuseKey(
    descriptor: HostManagedProcessDescriptor,
    actionIndex: Int
  ) -> RockchipRuntimeObservationReuseCache.LoaderKey? {
    let suffix = "-a\(actionIndex)"
    guard descriptor.stepID.hasSuffix(suffix) else { return nil }
    let controlAttempt = String(descriptor.stepID.dropLast(suffix.count))
    guard let marker = controlAttempt.range(of: "-mc-", options: .backwards) else {
      return nil
    }
    let step = controlAttempt[..<marker.lowerBound]
    let requestDigest = controlAttempt[marker.upperBound...]
    guard !step.isEmpty, requestDigest.count == 12,
      requestDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return nil }
    return RockchipRuntimeObservationReuseCache.LoaderKey(
      jobID: descriptor.jobID,
      targetID: descriptor.targetID,
      bindingRevision: descriptor.bindingRevision,
      stableIdentitySHA256: descriptor.expectedIdentitySHA256,
      controlAttempt: controlAttempt)
  }

  private static func boundHDCReuseKey(
    descriptor: HostManagedProcessDescriptor,
    expectation: RockchipHDCReconnectExpectation
  ) -> RockchipRuntimeObservationReuseCache.BoundHDCKey {
    RockchipRuntimeObservationReuseCache.BoundHDCKey(
      jobID: descriptor.jobID,
      targetID: descriptor.targetID,
      bindingRevision: descriptor.bindingRevision,
      stableIdentitySHA256: descriptor.expectedIdentitySHA256,
      previousIdentitySHA256: expectation.previousIdentitySHA256,
      usbTopology: expectation.usbTopology)
  }

  private func waitForLoader(
    stableIdentitySHA256: String,
    timeoutSeconds: Int,
    pollIntervalMilliseconds: Int = 1_000,
    requestID: String
  ) async throws -> RockchipRuntimeLoaderIdentity {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
      if let identity = try? exactLoaderIdentity(
        stableIdentitySHA256: stableIdentitySHA256),
        let confirmed = try? confirmLoader(
          identity,
          stableIdentitySHA256: stableIdentitySHA256,
          expectedUSBTopology: identity.topology,
          requestID: requestID)
      {
        return confirmed
      }
      try await Task.sleep(for: .milliseconds(pollIntervalMilliseconds))
    }
    throw RuntimeDispatchFailure.failed(
      "the bound DAYU200 did not appear as one exact Loader target")
  }

  private func exactLoaderIdentity(
    stableIdentitySHA256: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    do {
      let identity = try usbProbe.singleLoader(
        stableIdentitySHA256: stableIdentitySHA256)
      guard identity.serialDigestSHA256 == stableIdentitySHA256 else {
        throw RuntimeDispatchFailure.failed(
          "Loader USB serial does not match the adopted target identity")
      }
      return identity
    } catch let failure as RuntimeDispatchFailure {
      throw failure
    } catch {
      throw RuntimeDispatchFailure.failed(
        "bound Loader USB identity is unavailable or ambiguous: \(error)")
    }
  }

  private func confirmLoader(
    _ identity: RockchipRuntimeLoaderIdentity,
    stableIdentitySHA256: String,
    expectedUSBTopology: String?,
    requestID: String
  ) throws -> RockchipRuntimeLoaderIdentity {
    do {
      return try loaderObserver.confirmLoader(
        identity,
        stableIdentitySHA256: stableIdentitySHA256,
        expectedUSBTopology: expectedUSBTopology,
        requestID: requestID)
    } catch {
      throw RuntimeDispatchFailure.failed(
        "ArkForge dual-source Loader observation failed: \(error)")
    }
  }

  private func properties(
    _ receipt: ProviderSubprocessReceipt,
    orderedKeys: [String]
  ) throws -> [String: String] {
    guard let text = String(data: receipt.stdout, encoding: .utf8) else {
      throw RuntimeDispatchFailure.failed(
        "post-flash property readback is not UTF-8")
    }
    let lines = text.split(whereSeparator: { $0.isNewline }).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard lines.count == orderedKeys.count else {
      throw RuntimeDispatchFailure.failed(
        "post-flash property readback did not return exactly \(orderedKeys.count) values")
    }
    var result: [String: String] = [:]
    for (key, line) in zip(orderedKeys, lines) {
      // An echoed property name must match this fixed command's order. Bare
      // values remain supported, including values that themselves contain an
      // equals sign, just as the single-property parser supported them.
      let echoedKnownKey = orderedKeys.first { line.hasPrefix($0) }
      guard echoedKnownKey == nil || echoedKnownKey == key else {
        throw RuntimeDispatchFailure.failed(
          "post-flash property readback order or key drifted")
      }
      let value = HDCObservationProviderAdapter.propertyValue(
        fromParamGetOutput: line, requestedKey: key)
      guard !value.isEmpty, value.count <= 400 else {
        throw RuntimeDispatchFailure.failed(
          "post-flash property \(key) is empty or oversized")
      }
      result[key] = value
    }
    return result
  }

  private func resolveHDC() throws -> ResolvedExecutable {
    do {
      return try hdcResolver.resolveExecutable(providerID: "hdc")
    } catch {
      throw RuntimeDispatchFailure.failed(
        "descriptor-bound HDC executable is unavailable: \(error)")
    }
  }

  private func run(
    executable: ResolvedExecutable,
    arguments: [String],
    timeoutSeconds: Int?,
    budget: Int,
    effectMayHaveOccurred: Bool = false,
    successMarker: String? = nil
  ) async throws -> ProviderSubprocessReceipt {
    let receipt = try await runner.run(
      executable: executable,
      arguments: arguments,
      timeoutSeconds: timeoutSeconds,
      outputByteBudget: budget,
      criticalNonInterruptible: false)
    try requireSemanticSuccess(
      receipt,
      effectMayHaveOccurred: effectMayHaveOccurred,
      successMarker: successMarker)
    return receipt
  }

  /// Native write progress covers the whole partition, so its output scales with
  /// the image, and capture keeps the *head* — while the success marker is the
  /// last thing printed. At 64 KiB the two smallest DAYU200 partitions fit and
  /// `boot_linux` (64 MiB, 16x `uboot`) did not, so every flash stopped at the
  /// third partition with a truncated capture and an absent marker while the
  /// tool itself exited 0. This budget clears the largest published partition
  /// (`system`, 2 GiB) with room to spare and stays bounded.
  private static let writeOutputByteBudget = 8 * 1024 * 1024

  /// The last captured output, reduced to one printable line. A truncated
  /// capture ends mid-progress, so this is the newest thing the tool said
  /// before the receipt was rejected — enough to tell a refused write from a
  /// budget that is still too small without re-running a destructive step.
  package static func outputExcerpt(_ data: Data, limit: Int = 200) -> String {
    let text = String(decoding: data.suffix(4 * limit), as: UTF8.self)
      .map { $0.isASCII && !$0.isNewline && $0 != "\r" ? $0 : " " }
    let collapsed = String(text).split(separator: " ").joined(separator: " ")
    return collapsed.count <= limit ? collapsed : "…" + String(collapsed.suffix(limit))
  }

  private func requireSemanticSuccess(
    _ receipt: ProviderSubprocessReceipt,
    effectMayHaveOccurred: Bool,
    successMarker: String? = nil
  ) throws {
    let clean =
      receipt.exitStatus == 0 && !receipt.stdoutTruncated && receipt.stderr.isEmpty
    let markerMatches: Bool
    if let successMarker {
      markerMatches =
        String(data: receipt.stdout, encoding: .utf8)?.contains(successMarker) == true
    } else {
      markerMatches = true
    }
    guard clean, markerMatches else {
      // Four different rejections used to collapse into one sentence, so an
      // operator holding an outcome-unknown destructive step could not tell a
      // non-zero exit from a truncated capture, from stderr output, from a
      // missing success marker — the 2026-08-04 GJ-4 flash-partitions stop had
      // to be diagnosed by re-reading the device instead. The reasons are named
      // here. Receipt text is not: stdout/stderr stay behind the same
      // byte-count-and-digest boundary the persisted receipt uses, so this adds
      // attribution without adding a new disclosure surface.
      var reasons: [String] = []
      if receipt.exitStatus != 0 {
        reasons.append("exitStatus=\(receipt.exitStatus.map(String.init) ?? "none")")
      }
      if receipt.stdoutTruncated { reasons.append("stdoutTruncated") }
      if !receipt.stderr.isEmpty {
        reasons.append("stderrByteCount=\(receipt.stderr.count)")
      }
      if !markerMatches { reasons.append("successMarkerAbsent") }
      reasons.append("stdoutCapturedBytes=\(receipt.stdout.count)")
      let detail =
        "typed command lacked a clean, complete semantic receipt "
        + "(\(reasons.joined(separator: ", "))); "
        + "last output: \(Self.outputExcerpt(receipt.stdout))"
      if effectMayHaveOccurred {
        throw RuntimeDispatchFailure.outcomeUnknown(detail)
      }
      throw RuntimeDispatchFailure.failed(detail)
    }
  }

  private func result(
    summary: [String: String],
    receipts: [ProviderSubprocessReceipt]
  ) -> RockchipRuntimeActionExecutionResult {
    var stdout = Data()
    var stderr = Data()
    for receipt in receipts {
      stdout.append(receipt.stdout)
      stderr.append(receipt.stderr)
    }
    return RockchipRuntimeActionExecutionResult(
      summary: summary,
      stdout: stdout,
      stderr: stderr,
      stdoutTruncated: receipts.contains(where: \.stdoutTruncated),
      subprocesses: receipts)
  }
}

private struct RockchipRuntimeHostIntentRecord: Codable, Equatable {
  let schemaVersion: String
  let jobID: String
  let stepID: String
  let targetID: String
  let bindingRevision: Int
  let stableIdentitySHA256: String
  let providerExecutableSHA256: String
  let actionSHA256: String
  let action: PersistedTypedProviderAction
}

private struct RockchipRuntimeHostReceiptRecord: Codable, Equatable {
  let schemaVersion: String
  let jobID: String
  let stepID: String
  let targetID: String
  let bindingRevision: Int
  let stableIdentitySHA256: String
  let providerExecutableSHA256: String
  let actionSHA256: String
  let summary: [String: String]
  let stdoutSHA256: String
  let stdoutByteCount: Int
  let stderrSHA256: String
  let stderrByteCount: Int
  let stdoutTruncated: Bool
  let subprocessCount: Int

  func matches(
    descriptor: HostManagedProcessDescriptor
  ) -> Bool {
    schemaVersion == "1.0.0"
      && jobID == descriptor.jobID
      && stepID == descriptor.stepID
      && targetID == descriptor.targetID
      && bindingRevision == descriptor.bindingRevision
      && stableIdentitySHA256 == descriptor.expectedIdentitySHA256
      && providerExecutableSHA256 == descriptor.providerExecutableSHA256
      && actionSHA256 == descriptor.actionSHA256
  }

  var isWellFormed: Bool {
    func validSHA256(_ value: String) -> Bool {
      value.count == 64
        && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    return validSHA256(stdoutSHA256)
      && validSHA256(stderrSHA256)
      && stdoutByteCount >= 0
      && stderrByteCount >= 0
      && subprocessCount >= 0
      && !summary.isEmpty
      && summary.count <= 64
      && summary.allSatisfy {
        !$0.key.isEmpty && $0.key.count <= 128 && $0.value.count <= 4_096
      }
  }
}

private enum RockchipRuntimeHostPreparation {
  case execute(URL)
  case replay(RockchipRuntimeActionExecutionResult)
}

struct RockchipRuntimeActionRecordStore: Sendable {
  let rootURL: URL

  func unavailableReason() -> String? {
    do {
      try prepareDirectory(rootURL, allowExisting: true)
      return nil
    } catch {
      return "durable Rockchip host record root is unavailable: \(error)"
    }
  }

  /// Projects only the already-confirmed Flash postflight receipt. This is a
  /// read-only compatibility path because the generic Job record carries
  /// preflight observations, while Flash proves these facts after reboot. It
  /// never dispatches or repairs an action and returns nil on correlation drift.
  func flashPostflightObservation(
    for record: RuntimeJobRecord
  ) -> RuntimeEvidenceObservation? {
    let stepID = "rebind-and-verify-build"
    guard ArkForgeFlashOperation.containsDurableRecordReference(record.operationReference),
      [CatalogProvider.arkforge.rawValue, "rockchip"].contains(record.providerID),
      ["succeeded", "recovered"].contains(record.state),
      !record.outcomeUnknown,
      let bindingRevision = record.request.target.expectedBindingRevision,
      bindingRevision == record.materializedBindingRevision,
      let stableIdentitySHA256 = record.materializedStableTargetIdentitySHA256,
      let confirmedAtUTC = record.finishedAtUTC,
      !confirmedAtUTC.isEmpty
    else { return nil }

    do {
      try validateComponent(record.jobID, field: "jobID")
      let directory =
        rootURL
        .appending(path: record.jobID, directoryHint: .isDirectory)
        .appending(path: stepID, directoryHint: .isDirectory)
      let intent = try read(
        RockchipRuntimeHostIntentRecord.self,
        from: directory.appending(path: "intent.json"))
      let receipt = try read(
        RockchipRuntimeHostReceiptRecord.self,
        from: directory.appending(path: "receipt.json"))
      let materializedAction = try intent.action.materialize()
      guard intent.schemaVersion == "1.0.0",
        intent.jobID == record.jobID,
        intent.stepID == stepID,
        intent.targetID == record.request.target.targetID,
        intent.bindingRevision == bindingRevision,
        intent.stableIdentitySHA256 == stableIdentitySHA256,
        receipt.schemaVersion == intent.schemaVersion,
        receipt.jobID == intent.jobID,
        receipt.stepID == intent.stepID,
        receipt.targetID == intent.targetID,
        receipt.bindingRevision == intent.bindingRevision,
        receipt.stableIdentitySHA256 == intent.stableIdentitySHA256,
        receipt.providerExecutableSHA256 == intent.providerExecutableSHA256,
        receipt.actionSHA256 == intent.actionSHA256,
        receipt.isWellFormed,
        case .rockchip(
          .verifyBoundBuild(
            let expectation, let expectedProductModel, let expectedBuildVersion)
        ) = materializedAction,
        receipt.summary["model"] == expectedProductModel,
        receipt.summary["firmware"] == expectedBuildVersion,
        receipt.summary["verification"] == "exact-published-profile-and-bound-hdc",
        receipt.summary["usbTopology"] == expectation.usbTopology,
        let hdcIdentitySHA256 = receipt.summary["hdcIdentitySha256"],
        hdcIdentitySHA256.count == 64,
        hdcIdentitySHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
      else { return nil }

      return RuntimeEvidenceObservation(
        targetID: record.request.target.targetID,
        bindingRevision: bindingRevision,
        stableIdentitySHA256: stableIdentitySHA256,
        model: expectedProductModel,
        firmware: expectedBuildVersion,
        transport: "usb",
        providerID: record.providerID,
        toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
        toolSHA256: receipt.providerExecutableSHA256,
        confirmedAtUTC: confirmedAtUTC,
        confirmationMethod: "machinePostflightReadback",
        preflightSteps: [])
    } catch {
      return nil
    }
  }

  fileprivate func prepare(
    descriptor: HostManagedProcessDescriptor,
    action: TypedProviderAction
  ) throws -> RockchipRuntimeHostPreparation {
    try validateComponent(descriptor.jobID, field: "jobID")
    try validateComponent(descriptor.stepID, field: "stepID")
    try prepareDirectory(rootURL, allowExisting: true)
    let jobDirectory = rootURL.appending(
      path:
        descriptor.jobID, directoryHint: .isDirectory)
    try prepareDirectory(jobDirectory, allowExisting: true)
    let actionDirectory = jobDirectory.appending(
      path:
        descriptor.stepID, directoryHint: .isDirectory)
    let record = RockchipRuntimeHostIntentRecord(
      schemaVersion: "1.0.0",
      jobID: descriptor.jobID,
      stepID: descriptor.stepID,
      targetID: descriptor.targetID,
      bindingRevision: descriptor.bindingRevision,
      stableIdentitySHA256: descriptor.expectedIdentitySHA256,
      providerExecutableSHA256: descriptor.providerExecutableSHA256,
      actionSHA256: descriptor.actionSHA256,
      action: try PersistedTypedProviderAction(action))
    let created = Darwin.mkdir(actionDirectory.path, 0o700) == 0
    if !created {
      guard errno == EEXIST else {
        throw RuntimeDispatchFailure.failed(
          "cannot create Rockchip record directory (errno \(errno))")
      }
      try prepareDirectory(actionDirectory, allowExisting: true)
      let existingIntent: RockchipRuntimeHostIntentRecord
      do {
        existingIntent = try read(
          RockchipRuntimeHostIntentRecord.self,
          from: actionDirectory.appending(path: "intent.json"))
      } catch {
        if action.effect >= .deviceMutation {
          throw RuntimeDispatchFailure.outcomeUnknown(
            "durable Rockchip mutation intent cannot be recovered: \(error)")
        }
        throw RuntimeDispatchFailure.failed(
          "durable Rockchip read-only intent cannot be recovered: \(error)")
      }
      guard existingIntent == record else {
        if action.effect >= .deviceMutation {
          throw RuntimeDispatchFailure.outcomeUnknown(
            "durable Rockchip mutation intent identity drifted; original not resent")
        }
        throw RuntimeDispatchFailure.failed(
          "durable Rockchip read-only intent identity drifted")
      }
      let receiptURL = actionDirectory.appending(path: "receipt.json")
      var receiptMetadata = stat()
      if lstat(receiptURL.path, &receiptMetadata) == 0 {
        let receipt: RockchipRuntimeHostReceiptRecord
        do {
          receipt = try read(
            RockchipRuntimeHostReceiptRecord.self, from: receiptURL)
        } catch {
          if action.effect >= .deviceMutation {
            throw RuntimeDispatchFailure.outcomeUnknown(
              "durable Rockchip mutation receipt cannot be recovered: \(error)")
          }
          throw RuntimeDispatchFailure.failed(
            "durable Rockchip read-only receipt cannot be recovered: \(error)")
        }
        guard receipt.matches(descriptor: descriptor), receipt.isWellFormed else {
          if action.effect >= .deviceMutation {
            throw RuntimeDispatchFailure.outcomeUnknown(
              "durable Rockchip mutation receipt is invalid; original not resent")
          }
          throw RuntimeDispatchFailure.failed(
            "durable Rockchip read-only receipt is invalid")
        }
        var summary = receipt.summary
        summary["recordID"] = recordID(descriptor: descriptor)
        return .replay(
          RockchipRuntimeActionExecutionResult(
            summary: summary,
            stdout: Data(),
            stderr: Data(),
            stdoutTruncated: receipt.stdoutTruncated,
            subprocesses: []))
      }
      guard errno == ENOENT else {
        throw RuntimeDispatchFailure.failed(
          "cannot inspect durable Rockchip receipt (errno \(errno))")
      }
      guard action.effect <= .readOnly else {
        throw RuntimeDispatchFailure.outcomeUnknown(
          "durable Rockchip mutation intent has no receipt; original not resent")
      }
      return .execute(actionDirectory)
    }
    try synchronizeDirectory(actionDirectory.deletingLastPathComponent())
    do {
      try write(record, to: actionDirectory.appending(path: "intent.json"))
    } catch {
      throw RuntimeDispatchFailure.failed(
        "cannot persist Rockchip host intent before dispatch: \(error)")
    }
    return .execute(actionDirectory)
  }

  func finish(
    descriptor: HostManagedProcessDescriptor,
    result: RockchipRuntimeActionExecutionResult,
    actionDirectory: URL
  ) throws -> String {
    let record = RockchipRuntimeHostReceiptRecord(
      schemaVersion: "1.0.0",
      jobID: descriptor.jobID,
      stepID: descriptor.stepID,
      targetID: descriptor.targetID,
      bindingRevision: descriptor.bindingRevision,
      stableIdentitySHA256: descriptor.expectedIdentitySHA256,
      providerExecutableSHA256: descriptor.providerExecutableSHA256,
      actionSHA256: descriptor.actionSHA256,
      summary: result.summary,
      stdoutSHA256: Self.sha256(result.stdout),
      stdoutByteCount: result.stdout.count,
      stderrSHA256: Self.sha256(result.stderr),
      stderrByteCount: result.stderr.count,
      stdoutTruncated: result.stdoutTruncated,
      subprocessCount: result.subprocesses.count)
    try write(record, to: actionDirectory.appending(path: "receipt.json"))
    return recordID(descriptor: descriptor)
  }

  private func recordID(
    descriptor: HostManagedProcessDescriptor
  ) -> String {
    "rockchip-runtime/\(descriptor.jobID)/\(descriptor.stepID)/receipt.json"
  }

  private func prepareDirectory(
    _ url: URL,
    allowExisting: Bool
  ) throws {
    guard url.isFileURL, url.path.hasPrefix("/"),
      url.standardizedFileURL.path == url.path
    else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip record path is not canonical")
    }
    let created = Darwin.mkdir(url.path, 0o700) == 0
    if !created {
      if !allowExisting, errno == EEXIST {
        throw RuntimeDispatchFailure.failed(
          "durable Rockchip action directory already exists; refusing duplicate dispatch")
      }
      guard allowExisting, errno == EEXIST else {
        throw RuntimeDispatchFailure.failed(
          "cannot create Rockchip record directory (errno \(errno))")
      }
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o077 == 0
    else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip record directory is not an owner-only real directory")
    }
    if created {
      try synchronizeDirectory(url.deletingLastPathComponent())
    }
  }

  private func validateComponent(_ value: String, field: String) throws {
    let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else {
      throw RuntimeDispatchFailure.failed(
        "\(field) is not a bounded path component")
    }
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = CanonicalJSONEncoders.canonical()
    let data = try encoder.encode(value)
    let temporary = url.deletingLastPathComponent().appending(
      path:
        ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
    let descriptor = Darwin.open(
      temporary.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600)
    guard descriptor >= 0 else {
      throw RuntimeDispatchFailure.failed(
        "cannot create owner-only Rockchip record (errno \(errno))")
    }
    do {
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.write(
            descriptor,
            bytes.baseAddress!.advanced(by: offset),
            bytes.count - offset)
          if count > 0 {
            offset += count
          } else if count < 0, errno == EINTR {
            continue
          } else {
            throw RuntimeDispatchFailure.failed(
              "cannot write Rockchip record (errno \(errno))")
          }
        }
      }
      guard fsync(descriptor) == 0 else {
        throw RuntimeDispatchFailure.failed(
          "cannot synchronize Rockchip record (errno \(errno))")
      }
    } catch {
      Darwin.close(descriptor)
      unlink(temporary.path)
      throw error
    }
    guard Darwin.close(descriptor) == 0 else {
      unlink(temporary.path)
      throw RuntimeDispatchFailure.failed(
        "cannot close Rockchip record (errno \(errno))")
    }
    guard rename(temporary.path, url.path) == 0 else {
      unlink(temporary.path)
      throw RuntimeDispatchFailure.failed(
        "cannot publish Rockchip record (errno \(errno))")
    }
    try synchronizeDirectory(url.deletingLastPathComponent())
  }

  private func read<T: Decodable>(
    _ type: T.Type,
    from url: URL
  ) throws -> T {
    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeDispatchFailure.failed(
        "cannot open Rockchip record (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o077 == 0,
      metadata.st_size > 0,
      metadata.st_size <= 1_048_576
    else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip record is not a bounded owner-only regular file")
    }
    var data = Data(count: Int(metadata.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          throw RuntimeDispatchFailure.failed(
            "cannot read complete Rockchip record (errno \(errno))")
        }
      }
    }
    return try JSONDecoder().decode(type, from: data)
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let directoryDescriptor = Darwin.open(
      url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryDescriptor >= 0 else {
      throw RuntimeDispatchFailure.failed(
        "cannot open Rockchip record directory for synchronization")
    }
    defer { Darwin.close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else {
      throw RuntimeDispatchFailure.failed(
        "cannot synchronize Rockchip record directory (errno \(errno))")
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }
}

struct DurableRockchipRuntimeActionHost: RockchipRuntimeActionHosting {
  private let executor: any RockchipRuntimeActionExecuting
  private let records: RockchipRuntimeActionRecordStore

  init(
    executor: any RockchipRuntimeActionExecuting,
    records: RockchipRuntimeActionRecordStore
  ) {
    self.executor = executor
    self.records = records
  }

  func unavailableReason() -> String? {
    executor.unavailableReason() ?? records.unavailableReason()
  }

  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable
  ) async throws -> RockchipRuntimeActionExecutionResult {
    try await execute(
      action: action, descriptor: descriptor,
      providerExecutable: providerExecutable, progress: { _ in })
  }

  func execute(
    action: RockchipProviderAction,
    descriptor: HostManagedProcessDescriptor,
    providerExecutable: ResolvedExecutable,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> RockchipRuntimeActionExecutionResult {
    let typedAction = TypedProviderAction.rockchip(action)
    try validate(
      action: typedAction,
      descriptor: descriptor,
      executable: providerExecutable)
    let preparation = try records.prepare(
      descriptor: descriptor, action: typedAction)
    if case .replay(let result) = preparation {
      return result
    }
    guard case .execute(let actionDirectory) = preparation else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip host preparation returned an invalid state")
    }
    let result = try await executor.execute(
      action: action,
      descriptor: descriptor,
      providerExecutable: providerExecutable,
      actionDirectory: actionDirectory,
      progress: progress)
    do {
      let recordID = try records.finish(
        descriptor: descriptor,
        result: result,
        actionDirectory: actionDirectory)
      var summary = result.summary
      summary["recordID"] = recordID
      return RockchipRuntimeActionExecutionResult(
        summary: summary,
        stdout: result.stdout,
        stderr: result.stderr,
        stdoutTruncated: result.stdoutTruncated,
        subprocesses: result.subprocesses)
    } catch {
      if typedAction.effect >= .deviceMutation {
        throw RuntimeDispatchFailure.outcomeUnknown(
          "external effect completed but its durable host receipt could not be persisted: \(error)")
      }
      throw RuntimeDispatchFailure.failed(
        "read-only host receipt could not be persisted: \(error)")
    }
  }

  private func validate(
    action: TypedProviderAction,
    descriptor: HostManagedProcessDescriptor,
    executable: ResolvedExecutable
  ) throws {
    guard descriptor.bindingRevision > 0,
      descriptor.expectedIdentitySHA256.count == 64,
      descriptor.expectedIdentitySHA256.allSatisfy({
        $0.isHexDigit && !$0.isUppercase
      }),
      descriptor.providerExecutableSHA256 == executable.sha256
    else {
      throw RuntimeDispatchFailure.failed(
        "host-managed target/binding/executable correlation is incomplete or drifted")
    }
    let encoder = CanonicalJSONEncoders.canonical()
    let encoded = try encoder.encode(try PersistedTypedProviderAction(action))
    let digest = SHA256Hex.string(of: encoded)
    guard digest == descriptor.actionSHA256 else {
      throw RuntimeDispatchFailure.failed(
        "host-managed typed action digest drifted after materialization")
    }
    guard actionMatchesDescriptor(action, descriptor: descriptor) else {
      throw RuntimeDispatchFailure.failed(
        "host-managed typed action does not match its target/descriptor")
    }
  }

  private func actionMatchesDescriptor(
    _ action: TypedProviderAction,
    descriptor: HostManagedProcessDescriptor
  ) -> Bool {
    // A host-only action never runs inside the Rockchip host-managed executor.
    guard case .rockchip(let rockchip) = action else { return false }
    // One identifier table, shared with materialization. The two used to be
    // separate literal lists, and a third site invented a descriptor that
    // matched neither; the catalog is now the only producer this check can
    // agree with.
    guard descriptor.identifier == RockchipHostManagedActionCatalog.identifier(for: rockchip)
    else { return false }
    switch rockchip {
    case .enterLoader(let connectKey),
      .observeHDCNormalUSB(let connectKey),
      .waitForHDCDisconnect(let connectKey),
      .waitForHDCReconnect(let connectKey),
      .capturePostFlashDiagnostics(let connectKey, _):
      return connectKey == descriptor.connectKey
    case .waitForLoader(let identity),
      .rebindLoader(let identity),
      .rebootToNormal(let identity):
      return identity == descriptor.expectedIdentitySHA256
    case .waitForBoundHDCReconnect(let expectation),
      .verifyBoundBuild(let expectation, _, _):
      return expectation.previousConnectKey == descriptor.connectKey
    }
  }
}
