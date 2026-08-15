// Production process dispatcher (CHG-2026-048, T11).
//
// Binds a lowered plan to the identity-verifying process executor:
// the executable is resolved by an injected resolver (production: HDC
// external-first discovery; tests: a fixture binary), its SHA-256 is
// re-verified by the executor's own O_NOFOLLOW/dev-ino/one-shot gates at
// spawn, and stdout/stderr are captured under the plan's byte budget.
// hostManaged plans are refused here - they belong to their own hosts.

import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import CryptoKit
import Foundation

package struct ResolvedExecutable: Sendable, Equatable {
  public let path: String
  public let sha256: String
  package let verifiedResources: [ResolvedExecutableResource]
  package let verifiedTrees: [ResolvedExecutableTreeResource]
  package let canonicalNamespaceRoot: String?

  public init(path: String, sha256: String) {
    self.path = path
    self.sha256 = sha256
    verifiedResources = []
    verifiedTrees = []
    canonicalNamespaceRoot = nil
  }

  package init(
    path: String,
    sha256: String,
    verifiedResources: [ResolvedExecutableResource],
    verifiedTrees: [ResolvedExecutableTreeResource] = [],
    canonicalNamespaceRoot: String? = nil
  ) {
    self.path = path
    self.sha256 = sha256
    self.verifiedResources = verifiedResources
    self.verifiedTrees = verifiedTrees
    self.canonicalNamespaceRoot = canonicalNamespaceRoot
  }
}

package struct ResolvedExecutableTreeResource: Sendable, Equatable {
  package let path: String
  package let sha256: String
}

package struct ResolvedExecutableResource: Sendable, Equatable {
  package let path: String
  package let sha256: String
  package let byteCount: Int
  package let requireExecutable: Bool
}

/// Resolves the tool binary for a provider at dispatch time. Production
/// composes discovery; tests point at a fixture binary.
package protocol RuntimeExecutableResolving: Sendable {
  func resolveExecutable(providerID: String) throws -> ResolvedExecutable
  func resolveExecutable(for action: TypedProviderAction) throws -> ResolvedExecutable
}

extension RuntimeExecutableResolving {
  package func resolveExecutable(for action: TypedProviderAction) throws -> ResolvedExecutable {
    let providerID: String
    switch action {
    case .hdc:
      providerID = "hdc"
    case .rockchip:
      providerID = "rockchip"
    case .workspace:
      providerID = "workspace"
    case .analyzer:
      providerID = "analyzer"
    }
    return try resolveExecutable(providerID: providerID)
  }
}

package struct FixedExecutableResolver: RuntimeExecutableResolving {
  private let table: [String: ResolvedExecutable]

  public init(table: [String: ResolvedExecutable]) {
    self.table = table
  }

  package static func hashing(path: String, providerID: String) throws -> FixedExecutableResolver {
    guard path.hasPrefix("/") else {
      throw RuntimeDispatchFailure.failed(
        "provider executable path must be explicit and absolute")
    }
    let executable = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
    let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      FileManager.default.isExecutableFile(atPath: executable.path)
    else {
      throw RuntimeDispatchFailure.failed(
        "provider executable must be a regular executable file: \(executable.path)")
    }
    let data = try Data(contentsOf: executable)
    let sha = SHA256Hex.string(of: data)
    return FixedExecutableResolver(
      table: [providerID: ResolvedExecutable(path: executable.path, sha256: sha)])
  }

  package func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard let resolved = table[providerID] else {
      throw RuntimeDispatchFailure.failed("no executable registered for provider \(providerID)")
    }
    return resolved
  }
}

package struct DescriptorBoundProcessDispatcher: RuntimeProcessDispatching {
  private let resolver: any RuntimeExecutableResolving
  private let outputByteBudget: Int
  private let childEnvironment: [String: String]
  private let processExecutor: FoundationProcessExecutor

  package init(
    resolver: any RuntimeExecutableResolving,
    outputByteBudget: Int = 8 * 1024 * 1024,
    childEnvironment: [String: String] = [:],
    processExecutor: FoundationProcessExecutor = FoundationProcessExecutor()
  ) {
    self.resolver = resolver
    self.outputByteBudget = outputByteBudget
    self.childEnvironment = childEnvironment
    self.processExecutor = processExecutor
  }

  /// HDC dispatcher for the daemon composition root. The spawn base
  /// environment is a closed allowlist, so a daemon-launcher
  /// `OHOS_HDC_SERVER_PORT` reaches hdc children only by being named here;
  /// otherwise hdc would silently address the default server.
  package static func hdc(
    resolver: any RuntimeExecutableResolving
  ) -> DescriptorBoundProcessDispatcher {
    DescriptorBoundProcessDispatcher(
      resolver: resolver,
      childEnvironment: HDCServerEndpointSelector.inheritedPortChildEnvironment())
  }

  package func unavailableReason(providerID: String) -> String? {
    do {
      _ = try resolver.resolveExecutable(providerID: providerID)
      return nil
    } catch {
      return "provider executable is unavailable: \(error)"
    }
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    let loweredInvocations: [TypedProcessInvocation]
    let isSequence: Bool
    switch plan.kind {
    case .process(_, let argv, let timeoutSeconds):
      isSequence = false
      loweredInvocations = [
        TypedProcessInvocation(arguments: argv, timeoutSeconds: timeoutSeconds)
      ]
    case .processSequence(_, let sequence):
      isSequence = true
      guard !sequence.isEmpty else {
        throw RuntimeDispatchFailure.failed("provider produced an empty process sequence")
      }
      loweredInvocations = sequence
    case .hostManaged, .hostWorkspace:
      throw RuntimeDispatchFailure.failed(
        "host-managed plans execute inside their own host, not this dispatcher")
    }
    let verifiedAnalyzerSource = try verifiedAnalyzerSource(
      for: plan.action, loweredInvocations: loweredInvocations)
    defer { verifiedAnalyzerSource?.close() }
    let invocations = try analyzerSourceBoundInvocations(
      loweredInvocations, action: plan.action, source: verifiedAnalyzerSource)
    let executable = try resolver.resolveExecutable(for: plan.action)
    let executableLaunchMode = executableLaunchMode(for: plan.action)
    if let landing = plan.hostLanding {
      do {
        try landing.prepareDestination()
      } catch {
        // Nothing was spawned yet, so nothing external happened.
        throw RuntimeDispatchFailure.failed(
          "cannot prepare host landing destination: \(error)")
      }
    }
    var subprocesses: [ProviderSubprocessReceipt] = []
    var aggregateStdout = Data()
    var aggregateStderr = Data()
    var anyTruncated = false
    for invocation in invocations {
      let subreceipt: ProviderSubprocessReceipt
      do {
        subreceipt = try await execute(
          invocation, executable: executable, argumentZero: plan.argumentZero,
          workingDirectory: plan.workingDirectory,
          executableLaunchMode: executableLaunchMode,
          verifiedAnalyzerSource: verifiedAnalyzerSource)
      } catch let failure as RuntimeDispatchFailure where isArkTraceOperation(plan.action) {
        // RuntimeDispatchFailure details produced below may embed the
        // authorized executable path. Preserve only the outcome class at the
        // durable/public ArkTrace boundary.
        switch failure {
        case .outcomeUnknown:
          throw RuntimeDispatchFailure.outcomeUnknown("analyzer process outcome unknown")
        case .confirmedNotExecuted, .confirmedNotExecutedWithDiagnostic, .failed:
          throw RuntimeDispatchFailure.failed("analyzer process identity refused")
        }
      } catch let cancellation as RuntimeDispatchCancellationResolution {
        throw cancellation
      } catch let failure as RuntimeDispatchFailure {
        throw failure
      } catch where isArkTraceOperation(plan.action) {
        // Process-layer diagnostics can contain the authorized executable
        // pathname. The trace operation's durable/public failure is a closed,
        // path-free code; low-level details stay inside the process boundary.
        throw RuntimeDispatchFailure.failed("analyzer process identity refused")
      }
      subprocesses.append(subreceipt)
      aggregateStdout.append(subreceipt.stdout)
      aggregateStderr.append(subreceipt.stderr)
      anyTruncated = anyTruncated || subreceipt.stdoutTruncated
      if subreceipt.exitStatus != 0, !invocation.continueAfterNonZero {
        break
      }
    }
    let last = subprocesses.last
    return ProviderProcessReceipt(
      exitStatus: last?.exitStatus,
      stdout: aggregateStdout,
      stderr: aggregateStderr,
      stdoutTruncated: anyTruncated,
      durationSeconds: subprocesses.reduce(0) { $0 + $1.durationSeconds },
      // Inspected even after a non-zero exit: a partial file that landed is
      // a fact the classifier needs, and a clean exit is not evidence that
      // anything landed at all.
      landedArtifact: plan.hostLanding?.inspectLanded(),
      subprocesses: isSequence ? subprocesses : [])
  }

  private func isArkTraceOperation(_ action: TypedProviderAction) -> Bool {
    guard case .analyzer(.analyze(let invocation)) = action else { return false }
    return ["trace-summary@1", "trace-analysis@1"].contains(invocation.analyzerRef)
  }

  /// Binds Analyzer input bytes once, before executable resolution and spawn.
  /// The child receives the retained inode alias rather than the mutable
  /// Artifact pathname, while the descriptor remains open through process
  /// drain. This is the same lease whose identity was recorded in the typed
  /// Analyzer action; no later path lookup can select different trace bytes.
  private func verifiedAnalyzerSource(
    for action: TypedProviderAction,
    loweredInvocations: [TypedProcessInvocation]
  ) throws -> VerifiedRegularFileDescriptor? {
    guard case .analyzer(.analyze(let invocation)) = action else { return nil }
    guard invocation.sourceByteCount > 0,
      invocation.arguments.last?.hasPrefix("/") == true,
      loweredInvocations.count == 1,
      loweredInvocations[0].arguments == invocation.arguments
    else {
      throw RuntimeDispatchFailure.failed("analyzer input Artifact identity refused")
    }
    do {
      let source = try VerifiedRegularFileDescriptor.open(
        path: URL(filePath: invocation.arguments.last!),
        expectedSHA256: invocation.sourceSHA256,
        maximumBytes: invocation.sourceByteCount)
      guard source.byteCount == invocation.sourceByteCount else {
        source.close()
        throw VerifiedRegularFileError.identityChanged
      }
      return source
    } catch {
      throw RuntimeDispatchFailure.failed("analyzer input Artifact identity refused")
    }
  }

  private func analyzerSourceBoundInvocations(
    _ invocations: [TypedProcessInvocation],
    action: TypedProviderAction,
    source: VerifiedRegularFileDescriptor?
  ) throws -> [TypedProcessInvocation] {
    guard case .analyzer(.analyze(let analyzer)) = action else { return invocations }
    guard let source, invocations.count == 1,
      invocations[0].arguments == analyzer.arguments,
      !analyzer.arguments.isEmpty
    else {
      throw RuntimeDispatchFailure.failed("analyzer input Artifact identity refused")
    }
    var arguments = analyzer.arguments
    arguments[arguments.index(before: arguments.endIndex)] = source.inodePath
    return [
      TypedProcessInvocation(
        arguments: arguments,
        timeoutSeconds: invocations[0].timeoutSeconds,
        continueAfterNonZero: invocations[0].continueAfterNonZero)
    ]
  }

  private func execute(
    _ invocation: TypedProcessInvocation,
    executable: ResolvedExecutable,
    argumentZero: String?,
    workingDirectory: String?,
    executableLaunchMode: ProcessExecutableLaunchMode,
    verifiedAnalyzerSource: VerifiedRegularFileDescriptor?
  ) async throws -> ProviderSubprocessReceipt {
    let request = ProcessRequest(
      executable: URL(filePath: executable.path),
      argumentZero: argumentZero,
      arguments: invocation.arguments,
      environment: childEnvironment,
      workingDirectory: workingDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) },
      timeout: invocation.timeoutSeconds.map(TimeInterval.init),
      executableLaunchMode: executableLaunchMode)
    let executor = processExecutor
    let verifiedNamespace: VerifiedDirectoryDescriptor?
    do {
      verifiedNamespace = try executable.canonicalNamespaceRoot.map {
        try VerifiedDirectoryDescriptor.openOwnerOnly(path: URL(filePath: $0))
      }
    } catch {
      throw RuntimeDispatchFailure.failed("dispatch bundle namespace identity refused")
    }
    defer { verifiedNamespace?.close() }
    guard executable.verifiedTrees.allSatisfy({
      ArkTraceDistributionTreeHasher.matches(
        rootPath: $0.path, expectedSHA256: $0.sha256)
    }) else {
      throw RuntimeDispatchFailure.failed("dispatch resource identity refused")
    }
    let verifiedResources: [VerifiedRegularFileDescriptor]
    do {
      verifiedResources = try executable.verifiedResources.map {
        let descriptor = try VerifiedRegularFileDescriptor.open(
          path: URL(filePath: $0.path),
          expectedSHA256: $0.sha256,
          maximumBytes: $0.byteCount,
          requireExecutable: $0.requireExecutable)
        guard descriptor.byteCount == $0.byteCount else {
          descriptor.close()
          throw VerifiedRegularFileError.identityChanged
        }
        return descriptor
      }
    } catch {
      throw RuntimeDispatchFailure.failed("dispatch resource identity refused")
    }
    defer { verifiedResources.forEach { $0.close() } }
    let launchResources = verifiedResources + (verifiedAnalyzerSource.map { [$0] } ?? [])
    let result: ProcessIdentityBoundExecutionResult
    do {
      result = try await executor.executeIdentityBound(
        ProcessIdentityBoundRequest(process: request, expectedSHA256: executable.sha256),
        verifiedResources: launchResources,
        verifiedNamespace: verifiedNamespace,
        captureLimit: outputByteBudget)
    } catch let error as ProcessExecutionError {
      if Task.isCancelled, case .launchAuthorizationInvalidated = error {
        // The identity-bound executor checks cancellation both before spawn
        // and while the child is START_SUSPENDED. In either position no
        // provider code has run and the executor has reaped any suspended
        // leader, so this is the same positive no-survivor proof as a drained
        // process group—not an ordinary launch failure.
        throw RuntimeDispatchCancellationResolution.drained
      }
      // Identity/authorization refusals are definite failures: the child
      // never launched, so nothing external happened.
      throw RuntimeDispatchFailure.failed("dispatch refused: \(error)")
    } catch {
      // Anything else leaves the external outcome unobservable.
      throw RuntimeDispatchFailure.outcomeUnknown("dispatch outcome unobservable: \(error)")
    }

    let execution = result.execution
    switch execution.termination {
    case .exited(let status):
      return ProviderSubprocessReceipt(
        exitStatus: status,
        stdout: execution.stdout.data,
        stderr: execution.stderr.data,
        stdoutTruncated:
          execution.stdout.wasTruncated || execution.stderr.wasTruncated,
        durationSeconds: 0)
    case .timedOut:
      throw RuntimeDispatchFailure.outcomeUnknown("process timed out before completion")
    case .cancelled:
      switch execution.processGroupTermination {
      case .noSurvivingMembers:
        throw RuntimeDispatchCancellationResolution.drained
      case .notRequested, .unconfirmed:
        throw RuntimeDispatchCancellationResolution.unconfirmed
      }
    case .signalled(let signal):
      throw RuntimeDispatchFailure.outcomeUnknown(
        RockchipHostProcessDiagnostics.signalDeath(signal))
    case .waitFailed(let code), .unrecognizedWaitStatus(let code):
      throw RuntimeDispatchFailure.outcomeUnknown("process wait status unresolved (\(code))")
    }
  }

  private func executableLaunchMode(
    for action: TypedProviderAction
  ) -> ProcessExecutableLaunchMode {
    // The reviewed ArkTrace CLI is an inner executable of a signed App and
    // must retain its canonical bundle path. All pre-existing standalone
    // analyzers retain the stable inode-path launch contract.
    if case .analyzer(.analyze(let invocation)) = action,
      ["trace-summary@1", "trace-analysis@1"].contains(invocation.analyzerRef)
    {
      return .verifiedCanonicalPath
    }
    return .stableInodePath
  }
}

/// Production routing stays on the typed action, never on a caller string or
/// on the host-managed descriptor's display text. This lets HDC and Rockchip
/// have independent executable/host gates while the Runtime keeps one
/// dispatch port.
package struct RuntimeProcessDispatcherRouter: RuntimeProcessDispatching {
  private let hdc: any RuntimeProcessDispatching
  private let rockchip: any RuntimeProcessDispatching
  /// Absent means this composition has no host-only route: a workspace plan is
  /// then refused, never silently sent somewhere else.
  private let workspace: (any RuntimeProcessDispatching)?
  /// Absent means this composition has no analyzer route: an analysis plan is
  /// refused rather than sent down the workspace route, which owns a
  /// different executable set (CHG-2026-055, TASK-HFA-007).
  private let analyzer: (any RuntimeProcessDispatching)?

  public init(
    hdc: any RuntimeProcessDispatching,
    rockchip: any RuntimeProcessDispatching,
    workspace: (any RuntimeProcessDispatching)? = nil,
    analyzer: (any RuntimeProcessDispatching)? = nil
  ) {
    self.hdc = hdc
    self.rockchip = rockchip
    self.workspace = workspace
    self.analyzer = analyzer
  }

  package func unavailableReason(providerID: String) -> String? {
    switch providerID {
    case "hdc":
      return hdc.unavailableReason(providerID: providerID)
    case "rockchip":
      return rockchip.unavailableReason(providerID: providerID)
    case "workspace":
      guard let workspace else {
        return "no dispatcher route is registered for provider workspace"
      }
      return workspace.unavailableReason(providerID: providerID)
    case "analyzer":
      guard let analyzer else {
        return "no dispatcher route is registered for provider analyzer"
      }
      return analyzer.unavailableReason(providerID: providerID)
    default:
      return "no dispatcher route is registered for provider \(providerID)"
    }
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    switch plan.action {
    case .hdc:
      return try await hdc.dispatch(plan)
    case .rockchip:
      return try await rockchip.dispatch(plan)
    case .workspace:
      guard let workspace else {
        throw RuntimeDispatchFailure.failed(
          "no dispatcher route is registered for provider workspace")
      }
      return try await workspace.dispatch(plan)
    case .analyzer:
      guard let analyzer else {
        throw RuntimeDispatchFailure.failed(
          "no dispatcher route is registered for provider analyzer")
      }
      return try await analyzer.dispatch(plan)
    }
  }
}
