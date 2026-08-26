import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// How long each dispatched invocation actually ran.
///
/// `ProviderSubprocessReceipt.durationSeconds` reported a literal zero for
/// every invocation ever dispatched. Nothing noticed because nothing read it -
/// and `ProviderProcessReceipt.durationSeconds` sums these, so every
/// process-sequence step reported a total duration of zero too.
///
/// A bounded run of stills is the first consumer: with no recorder on the
/// platform, the only honest thing a screen sequence can say about its rate is
/// what it observed, and there is nowhere else to observe it. This pins the
/// measurement against a real child process, because a fake that supplies its
/// own durations is exactly what let the zero stand.
final class DispatchedInvocationDurationContractTests: XCTestCase {
  func testEveryDispatchedInvocationReportsHowLongItActuallyRan() async throws {
    let resolver = try FixedExecutableResolver.hashing(path: "/bin/sleep", providerID: "hdc")
    let dispatcher = DescriptorBoundProcessDispatcher(resolver: resolver)
    let plan = TypedProcessPlan(
      action: .hdc(.observeTool),
      kind: .processSequence(
        executableSHA256: "resolved-at-dispatch",
        invocations: [
          TypedProcessInvocation(arguments: ["0.30"], timeoutSeconds: 30),
          TypedProcessInvocation(arguments: ["0.05"], timeoutSeconds: 30),
        ]))
    let receipt = try await dispatcher.dispatch(plan)

    XCTAssertEqual(receipt.subprocesses.count, 2)
    let slow = receipt.subprocesses[0].durationSeconds
    let quick = receipt.subprocesses[1].durationSeconds
    XCTAssertGreaterThan(
      slow, 0.25,
      "a child that slept 300 ms cannot be reported as having taken \(slow)s")
    XCTAssertGreaterThan(
      slow, quick,
      "the durations must track the invocations they belong to, not a constant")
    XCTAssertGreaterThan(
      receipt.durationSeconds, slow,
      "the sequence's total is the sum of what its invocations took")
  }
}
