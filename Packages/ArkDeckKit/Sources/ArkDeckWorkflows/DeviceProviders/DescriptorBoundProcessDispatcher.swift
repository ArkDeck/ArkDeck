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

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .process(_, let argv, let timeoutSeconds) = plan.kind else {
      throw RuntimeDispatchFailure.failed(
        "hostManaged plans execute inside their own host, not this dispatcher")
    }
    let providerID: String
    switch plan.action {
    case .hdc: providerID = "hdc"
    case .rockchip: providerID = "rockchip"
    }
    let executable = try resolver.resolveExecutable(providerID: providerID)
    let request = ProcessRequest(
      executable: URL(fileURLWithPath: executable.path),
      arguments: argv,
      timeout: timeoutSeconds.map(TimeInterval.init))
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
      return ProviderProcessReceipt(
        exitStatus: status,
        stdout: execution.stdout.data,
        stderr: execution.stderr.data,
        stdoutTruncated: execution.stdout.wasTruncated,
        durationSeconds: 0)
    case .timedOut:
      // A timeout says nothing about whether the device-side effect ran.
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
