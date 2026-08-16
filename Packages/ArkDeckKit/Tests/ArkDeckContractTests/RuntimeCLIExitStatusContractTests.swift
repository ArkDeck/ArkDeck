// `arkdeck job ...` exit-status mapping.
//
// PRODUCT-LOOP §14 puts the human budget at 0 after adoption, so this surface
// is driven by scripts and by the bounded debug loop rather than by a person
// reading the output. Exit 0 is the universal "it worked" signal: a failed,
// cancelled or outcome-unknown Job that exits 0 is read as a device that was
// successfully touched when it was not.

import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

final class RuntimeCLIExitStatusContractTests: XCTestCase {
  private func status(_ state: String, outcomeUnknown: Bool = false) -> JSONValue {
    .object([
      "jobId": .string("JOB-1"),
      "state": .string(state),
      "outcomeUnknown": .bool(outcomeUnknown),
    ])
  }

  func testASucceededOrStillRunningJobLeavesTheProcessAtZero() {
    for state in ["succeeded", "recovered", "planned", "running", "preflight", "queued"] {
      XCTAssertNil(
        RuntimeCLI.terminalJobExit(status(state)),
        "\(state) must not turn into a non-zero exit")
    }
  }

  func testAFailedTerminalJobDoesNotExitZero() {
    for state in ["failed", "cancelled", "interrupted"] {
      guard let terminal = RuntimeCLI.terminalJobExit(status(state)) else {
        return XCTFail("\(state) must not be reported as success")
      }
      XCTAssertEqual(terminal.code, 1, state)
      XCTAssertTrue(terminal.reason.contains(state), "the reason must name the state")
    }
  }

  /// An unknown outcome is not a failure to retry: POL-RECOVERY-001 forbids
  /// replaying the original effect, so it gets its own status and its own
  /// instruction. It also outranks the state, because a Job can reach a
  /// terminal state while the effect it dispatched stays undetermined.
  func testAnUnknownOutcomeGetsItsOwnStatusAndOutranksTheState() {
    guard let unknown = RuntimeCLI.terminalJobExit(status("failed", outcomeUnknown: true)) else {
      return XCTFail("an unknown outcome must not be reported as success")
    }
    XCTAssertEqual(unknown.code, 75)
    XCTAssertTrue(unknown.reason.contains("reconcile"))

    guard
      let stillUnknown = RuntimeCLI.terminalJobExit(status("succeeded", outcomeUnknown: true))
    else {
      return XCTFail("outcomeUnknown must outrank a succeeded state")
    }
    XCTAssertEqual(stillUnknown.code, 75)
  }

  /// The mapping is exhaustive over the state machine rather than over the
  /// states that happened to exist when it was written: a new terminal state
  /// must be classified deliberately instead of inheriting exit 0.
  func testEveryTerminalJobStateIsClassified() {
    let succeedingTerminals: Set<JobState> = [.planned, .succeeded, .recovered]
    for state in JobState.allCases where state.isTerminal {
      let mapped = RuntimeCLI.terminalJobExit(status(state.rawValue))
      if succeedingTerminals.contains(state) {
        XCTAssertNil(mapped, "\(state.rawValue) is a success terminal")
      } else {
        XCTAssertNotNil(
          mapped,
          "\(state.rawValue) is a terminal state that did not succeed and must not exit 0")
      }
    }
  }

  func testAResponseThatIsNotAJobStatusIsLeftAlone() {
    XCTAssertNil(RuntimeCLI.terminalJobExit(.string("not a status")))
    XCTAssertNil(RuntimeCLI.terminalJobExit(.object(["cancelRequested": .bool(true)])))
  }
}
