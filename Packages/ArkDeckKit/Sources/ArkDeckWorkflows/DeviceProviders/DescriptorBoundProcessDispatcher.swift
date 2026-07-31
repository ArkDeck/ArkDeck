// Production process dispatcher (CHG-2026-048, T11).
//
// Binds a lowered plan to the identity-verifying process executor:
// the executable is resolved by an injected resolver (production: HDC
// external-first discovery; tests: a fixture binary), its SHA-256 is
// re-verified by the executor's own O_NOFOLLOW/dev-ino/one-shot gates at
// spawn, and stdout/stderr are captured under the plan's byte budget.
// hostManaged plans are refused here - they belong to their own hosts.

import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Foundation

public struct ResolvedExecutable: Sendable, Equatable {
  public let path: String
  public let sha256: String

  public init(path: String, sha256: String) {
    self.path = path
    self.sha256 = sha256
  }
}

/// Resolves the tool binary for a provider at dispatch time. Production
/// composes discovery; tests point at a fixture binary.
public protocol RuntimeExecutableResolving: Sendable {
  func resolveExecutable(providerID: String) throws -> ResolvedExecutable
}

public struct FixedExecutableResolver: RuntimeExecutableResolving {
  private let table: [String: ResolvedExecutable]

  public init(table: [String: ResolvedExecutable]) {
    self.table = table
  }

  public static func hashing(path: String, providerID: String) throws -> FixedExecutableResolver {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return FixedExecutableResolver(
      table: [providerID: ResolvedExecutable(path: path, sha256: sha)])
  }

  public func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard let resolved = table[providerID] else {
      throw RuntimeDispatchFailure.failed("no executable registered for provider \(providerID)")
    }
    return resolved
  }
}

public struct DescriptorBoundProcessDispatcher: RuntimeProcessDispatching {
  private let resolver: any RuntimeExecutableResolving
  private let outputByteBudget: Int

  public init(resolver: any RuntimeExecutableResolving, outputByteBudget: Int = 8 * 1024 * 1024) {
    self.resolver = resolver
    self.outputByteBudget = outputByteBudget
  }

  public func unavailableReason(providerID: String) -> String? {
    do {
      _ = try resolver.resolveExecutable(providerID: providerID)
      return nil
    } catch {
      return "provider executable is unavailable: \(error)"
    }
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    let invocations: [TypedProcessInvocation]
    let isSequence: Bool
    switch plan.kind {
    case .process(_, let argv, let timeoutSeconds):
      isSequence = false
      invocations = [
        TypedProcessInvocation(arguments: argv, timeoutSeconds: timeoutSeconds)
      ]
    case .processSequence(_, let sequence):
      isSequence = true
      guard !sequence.isEmpty else {
        throw RuntimeDispatchFailure.failed("provider produced an empty process sequence")
      }
      invocations = sequence
    case .hostManaged:
      throw RuntimeDispatchFailure.failed(
        "hostManaged plans execute inside their own host, not this dispatcher")
    }
    let providerID: String
    switch plan.action {
    case .hdc: providerID = "hdc"
    case .rockchip: providerID = "rockchip"
    }
    let executable = try resolver.resolveExecutable(providerID: providerID)
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
      let subreceipt = try await execute(
        invocation, executable: executable)
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

  private func execute(
    _ invocation: TypedProcessInvocation,
    executable: ResolvedExecutable
  ) async throws -> ProviderSubprocessReceipt {
    let request = ProcessRequest(
      executable: URL(fileURLWithPath: executable.path),
      arguments: invocation.arguments,
      timeout: invocation.timeoutSeconds.map(TimeInterval.init))
    let executor = FoundationProcessExecutor()
    let result: ProcessIdentityBoundExecutionResult
    do {
      result = try await executor.executeIdentityBound(
        ProcessIdentityBoundRequest(process: request, expectedSHA256: executable.sha256),
        captureLimit: outputByteBudget)
    } catch let error as ProcessExecutionError {
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
        stdoutTruncated: execution.stdout.wasTruncated,
        durationSeconds: 0)
    case .timedOut:
      throw RuntimeDispatchFailure.outcomeUnknown("process timed out before completion")
    case .cancelled:
      throw RuntimeDispatchFailure.outcomeUnknown("process cancelled mid-flight")
    case .signalled(let signal):
      throw RuntimeDispatchFailure.outcomeUnknown("process died on signal \(signal)")
    case .waitFailed(let code), .unrecognizedWaitStatus(let code):
      throw RuntimeDispatchFailure.outcomeUnknown("process wait status unresolved (\(code))")
    }
  }
}

/// Production routing stays on the typed action, never on a caller string or
/// on the host-managed descriptor's display text. This lets HDC and Rockchip
/// have independent executable/host gates while the Runtime keeps one
/// dispatch port.
public struct RuntimeProcessDispatcherRouter: RuntimeProcessDispatching {
  private let hdc: any RuntimeProcessDispatching
  private let rockchip: any RuntimeProcessDispatching

  public init(
    hdc: any RuntimeProcessDispatching,
    rockchip: any RuntimeProcessDispatching
  ) {
    self.hdc = hdc
    self.rockchip = rockchip
  }

  public func unavailableReason(providerID: String) -> String? {
    switch providerID {
    case "hdc":
      return hdc.unavailableReason(providerID: providerID)
    case "rockchip":
      return rockchip.unavailableReason(providerID: providerID)
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
    }
  }
}
