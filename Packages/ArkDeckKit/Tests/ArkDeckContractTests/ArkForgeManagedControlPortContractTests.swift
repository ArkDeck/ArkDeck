import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

/// `AFA-AC-5`: the four semantic control actions, and what a receipt may carry.
///
/// Two properties are worth more than the mapping itself. First, `enterUpdater`
/// is three observations rather than one command — reporting success on the
/// command alone records a fact about the *message* as a fact about the
/// *device*. Second, a receipt is the only thing ArkForge learns about the
/// device from this side, so what must never travel is stopped where the
/// receipt is built, not discovered when the daemon rejects it.
final class ArkForgeManagedControlPortContractTests: XCTestCase {

  private let evidence = [UInt8](repeating: 0x9A, count: 32)

  private func modeFacts() -> [String: String] {
    [
      "mode": "Loader",
      "stableIdentitySHA256": String(repeating: "a", count: 64),
      "usbTopology": "0x14200000",
    ]
  }

  // MARK: - The published mapping

  func testEveryControlActionBindsToTheActionsArkForgePublishes() {
    // The canonical table is ArkForge's control.rs; this is the executable
    // other half. A divergence here means the two repositories disagree about
    // what a semantic action *is*.
    XCTAssertEqual(
      ArkForgeManagedControlPort.providerActions(for: .enterUpdater),
      [
        "observeHDCNormalUSB", "enterLoader", "waitForHDCDisconnect",
        "waitForLoader", "rebindLoader",
      ])
    XCTAssertEqual(
      ArkForgeManagedControlPort.providerActions(for: .rebootToNormal),
      ["waitForBoundHDCReconnect"])
    XCTAssertEqual(
      ArkForgeManagedControlPort.providerActions(for: .readProductFacts), ["verifyBoundBuild"])
    XCTAssertEqual(
      ArkForgeManagedControlPort.providerActions(for: .readBuildFacts), ["verifyBoundBuild"])
  }

  func testEnteringTheLoaderIsFiveObservationsNotOneCommand() {
    // The specific regression: mapping this to `enterLoader` alone.
    let actions = ArkForgeManagedControlPort.providerActions(for: .enterUpdater)
    for required in ["enterLoader", "waitForHDCDisconnect", "waitForLoader", "rebindLoader"] {
      XCTAssertTrue(actions.contains(required), "entering the Loader must include \(required)")
    }
    XCTAssertGreaterThan(actions.count, 1, "one command cannot establish three facts")
  }

  func testAnUnspecifiedActionBindsToNothing() {
    // Fail closed: an action this build does not know must not fall through to
    // some default sequence that touches the device.
    XCTAssertTrue(ArkForgeManagedControlPort.providerActions(for: .unspecified).isEmpty)
    XCTAssertTrue(ArkForgeManagedControlPort.expectedReceiptFacts(for: .unspecified).isEmpty)
  }

  // MARK: - What a receipt may never carry

  func testAForbiddenKeyRefusesTheWholeReceipt() throws {
    // Not "the field is dropped and the rest is sent" — the daemon rejects the
    // whole receipt, so this side refuses to build one.
    for forbidden in ["connectKey", "hdcExecutablePath", "hdcEndpoint", "argv", "shell",
      "serverLifecycleAction"]
    {
      var facts = modeFacts()
      facts[forbidden] = "anything"
      XCTAssertThrowsError(
        try ArkForgeManagedControlPort.receipt(
          jobID: "JOB-1", requestID: "REQ-1", action: .enterUpdater,
          observation: .init(
            accepted: true, facts: facts, evidenceSHA256: evidence,
            observedDisconnect: true, observedUniqueLoaderRebind: true)),
        forbidden
      ) { error in
        XCTAssertEqual(
          error as? ArkForgeManagedControlPort.ReceiptRefusal, .forbiddenFact(forbidden))
      }
    }
  }

  func testAForbiddenNameHiddenInAValueIsAlsoRefused() throws {
    // A receipt that puts the connect key in a message string leaks it just as
    // well as one that puts it in a key. This is the shape a well-meaning
    // diagnostic message takes.
    var facts = modeFacts()
    facts["detail"] = "retried after the connectKey changed"
    XCTAssertThrowsError(
      try ArkForgeManagedControlPort.receipt(
        jobID: "JOB-1", requestID: "REQ-1", action: .enterUpdater,
        observation: .init(
          accepted: true, facts: facts, evidenceSHA256: evidence,
          observedDisconnect: true, observedUniqueLoaderRebind: true))
    ) { error in
      guard case ArkForgeManagedControlPort.ReceiptRefusal.forbiddenFact(let where0) = error
      else { return XCTFail("expected a forbidden-fact refusal, got \(error)") }
      XCTAssertTrue(where0.contains("connectKey"), where0)
    }
  }

  func testACleanReceiptIsBuiltWithItsFactsSorted() throws {
    let receipt = try ArkForgeManagedControlPort.receipt(
      jobID: "JOB-1", requestID: "REQ-1", action: .enterUpdater,
      observation: .init(
        accepted: true, facts: modeFacts(), evidenceSHA256: evidence,
        observedDisconnect: true, observedUniqueLoaderRebind: true))
    XCTAssertTrue(receipt.accepted)
    XCTAssertEqual(receipt.facts.map(\.key), ["mode", "stableIdentitySHA256", "usbTopology"])
    XCTAssertEqual(receipt.evidenceSHA256, evidence)
    XCTAssertTrue(receipt.failureReason.isEmpty)
  }

  // MARK: - Success must carry its own evidence

  func testEnterUpdaterCannotClaimSuccessOnTheCommandAlone() throws {
    // The heart of AFA-AC-5. Accepted, facts present, but the disconnect and
    // the rebind were never observed — which is precisely "the command was
    // accepted", and precisely not "the device is in Loader".
    XCTAssertThrowsError(
      try ArkForgeManagedControlPort.receipt(
        jobID: "JOB-1", requestID: "REQ-1", action: .enterUpdater,
        observation: .init(
          accepted: true, facts: modeFacts(), evidenceSHA256: evidence,
          observedDisconnect: false, observedUniqueLoaderRebind: false))
    ) { error in
      guard case ArkForgeManagedControlPort.ReceiptRefusal
        .enterUpdaterWithoutFullObservation(let missing) = error
      else { return XCTFail("expected an incomplete-observation refusal, got \(error)") }
      XCTAssertEqual(missing.count, 2)
    }

    // Either one alone is still not enough.
    for (disconnect, rebind) in [(true, false), (false, true)] {
      XCTAssertThrowsError(
        try ArkForgeManagedControlPort.receipt(
          jobID: "JOB-1", requestID: "REQ-1", action: .enterUpdater,
          observation: .init(
            accepted: true, facts: modeFacts(), evidenceSHA256: evidence,
            observedDisconnect: disconnect, observedUniqueLoaderRebind: rebind)))
    }
  }

  func testSuccessWithoutTheFactsThatWouldEvidenceItIsRefused() throws {
    // `readBuildFacts` claiming success while carrying no build fact is a
    // claim, not an observation — and it is the exact shape of the postflight
    // failure AF-011 exists to stop.
    XCTAssertThrowsError(
      try ArkForgeManagedControlPort.receipt(
        jobID: "JOB-1", requestID: "REQ-1", action: .readBuildFacts,
        observation: .init(accepted: true, facts: [:], evidenceSHA256: evidence))
    ) { error in
      guard case ArkForgeManagedControlPort.ReceiptRefusal
        .successWithoutItsFacts(_, let missing) = error
      else { return XCTFail("expected a missing-facts refusal, got \(error)") }
      XCTAssertEqual(missing, ["const.ohos.fullname"])
    }

    // With the fact present it builds.
    let ok = try ArkForgeManagedControlPort.receipt(
      jobID: "JOB-1", requestID: "REQ-1", action: .readBuildFacts,
      observation: .init(
        accepted: true, facts: ["const.ohos.fullname": "OpenHarmony-7.0.0.36"],
        evidenceSHA256: evidence))
    XCTAssertEqual(ok.facts.first?.value, "OpenHarmony-7.0.0.36")
  }

  func testAFailedObservationNeedsNoFactsAndIsNotAClaimThatNothingHappened() throws {
    // `accepted: false` does not mean "nothing happened": a mode change may
    // have taken effect unobserved, and the daemon records that as an unknown
    // outcome. So a failed receipt is allowed to be thin — but the reason
    // travels, because that is where "it definitely did not happen" would have
    // to be argued.
    let receipt = try ArkForgeManagedControlPort.receipt(
      jobID: "JOB-1", requestID: "REQ-1", action: .enterUpdater,
      observation: .init(
        accepted: false, facts: [:], evidenceSHA256: evidence,
        failureReason: "no device rebound within the 15,579 ms window measured in AD-020"))
    XCTAssertFalse(receipt.accepted)
    XCTAssertTrue(receipt.facts.isEmpty)
    XCTAssertTrue(receipt.failureReason.contains("15,579"))
  }

  // MARK: - The other two places a secret can escape

  func testTheSameScanCoversJournalAndUIText() {
    // The receipt is not the only exit. The same facts are written to the
    // runtime journal and published as UI events; a connect key that leaks
    // there has leaked.
    XCTAssertEqual(
      ArkForgeManagedControlPort.leakedFacts(
        in: "flash step 3 dispatched via connectKey=127.0.0.1:5555 using argv [wlx]"),
      ["argv", "connectKey"])
    XCTAssertTrue(
      ArkForgeManagedControlPort.leakedFacts(
        in: "flash step 3 dispatched; mode=Loader, stableIdentitySHA256=abc").isEmpty)
  }

  func testTheForbiddenListMatchesArkForgesByteForByte() {
    // ArkForge's FORBIDDEN_RECEIPT_FACTS. A list that drifted would let this
    // side build a receipt the daemon then rejects wholesale — the failure
    // would be real but reported far from its cause.
    XCTAssertEqual(
      ArkForgeManagedControlPort.forbiddenReceiptFacts,
      ["connectKey", "hdcExecutablePath", "hdcEndpoint", "argv", "shell",
       "serverLifecycleAction"])
  }
}
