import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

// TASK-AIN-003 (CHG-2026-025) contract tests for the REQ-FLASH-015 standing-authorization
// path: AC-FLASH-015-01 (no authorization → policyBlocked), AC-FLASH-015-02 (any pin,
// validity or readback deviation → zero dispatch) and AC-FLASH-015-03 (a maintainer-merged
// authorization that matches pin-by-pin authorizes unattended agent execution).
//
// Fault-injection rule (TR-002R precedent): every negative case mutates the REAL
// authorization JSON bytes and goes through the real parse + compare path. No branch is
// exercised with a hand-built fake verdict.

final class StandingAuthorizationContractTests: XCTestCase {
  private let provider = RockchipRockUSBFlashProvider()
  private let now = "2026-07-22T12:00:00Z"
  private let serialDigest = StandingAuthorizationContractTests.sha256Hex(
    Data("dayu200-test-serial".utf8))

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - fixtures (real JSON bytes, real parse path)

  private func authorizationDictionary(plan: RockchipFlashPlan) -> [String: Any] {
    [
      "schemaVersion": "1.0.0",
      "authorizationId": "AUTH-2026-025-DAYU200-001",
      "approvedBy": "lvye",
      "carrier": "PR #999 evidence/authorizations/AUTH-2026-025-DAYU200-001.json@0123abcd",
      "target": [
        "model": RockchipFlashProfile.targetDeviceModel,
        "serialSHA256": serialDigest,
        "bindingRevision": 3,
      ],
      "firmwareArchiveSHA256": plan.archiveSHA256,
      "transport": "usb",
      "toolchainFingerprint": RockchipFlashProfile.pinnedToolchainFingerprint,
      "providerIdentity": RockchipRockUSBFlashProvider.providerIdentity,
      "planDigestSHA256": plan.planDigestSHA256,
      "stepSetDigestSHA256": plan.stepSetDigestSHA256,
      "recoveryPath": "CHG-2026-016 Loader wlx re-flash (archived runbook)",
      "validUntil": "2026-08-31T00:00:00Z",
      "maxRuns": 0,
    ]
  }

  private func parse(_ dictionary: [String: Any]) throws -> RockchipStandingAuthorization {
    let data = try JSONSerialization.data(withJSONObject: dictionary)
    return try RockchipStandingAuthorization.parse(data)
  }

  private func realBinding() -> RockchipRealDeviceBinding {
    RockchipRealDeviceBinding(
      usbVendorID: 0x2207, usbProductID: 0x350a, usbLocationID: "0x01100000")
  }

  private func matchingReadback() -> RockchipDeviceIdentityReadback {
    RockchipDeviceIdentityReadback(
      serialDigestSHA256: serialDigest,
      usbVendorID: 0x2207,
      usbProductID: 0x350a,
      readAtTimestamp: now)
  }

  private func context(
    priorRunCount: Int = 0,
    durableBindingRevision: Int = 3,
    readback: RockchipDeviceIdentityReadback? = nil,
    currentTimestamp: String? = nil
  ) -> RockchipStandingAuthorizationContext {
    RockchipStandingAuthorizationContext(
      currentTimestamp: currentTimestamp ?? now,
      priorRunCount: priorRunCount,
      durableBindingRevision: durableBindingRevision,
      identityReadback: readback ?? matchingReadback())
  }

  private func decide(
    authority: RockchipExecutionAuthority = .standardAgent,
    plan: RockchipFlashPlan,
    authorization: RockchipStandingAuthorization?,
    context: RockchipStandingAuthorizationContext?,
    binding: RockchipDeviceBindingState? = nil,
    prerequisites: RockchipPrerequisiteGateResult = .cleared
  ) async -> RockchipAuthorizationDecision {
    await RockchipFlashAuthorizationGate().authorize(
      authority: authority,
      binding: binding ?? .realDevice(realBinding()),
      plan: plan,
      prerequisites: prerequisites,
      destructiveConfirmationAccepted: false,
      manualConfirmation: nil,
      standingAuthorization: authorization,
      standingContext: context,
      monitor: RockchipFlashDispatchMonitor())
  }

  private func assertZeroDispatchBlocked(
    _ decision: RockchipAuthorizationDecision, _ message: String
  ) {
    XCTAssertEqual(decision.dispatchSnapshot.totalDispatchCount, 0, message)
    XCTAssertEqual(decision.evidenceEligibility, .notEligible, message)
    XCTAssertNil(decision.authorizationRef, message)
  }

  // MARK: - AC-FLASH-015-01 standing-authorization face

  func testTEST_AC_FLASH_015_01_MissingAuthorizationAndOrdinaryCIStayPolicyBlocked()
    async throws
  {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    let authorization = try parse(authorizationDictionary(plan: plan))

    // Agent with no standing authorization at all: policyBlocked, handoff names the
    // missing carrier.
    let missing = await decide(plan: plan, authorization: nil, context: nil)
    guard case .policyBlocked(let handoff) = missing.outcome else {
      return XCTFail("agent execute without authorization must be policyBlocked")
    }
    XCTAssertEqual(missing.jobMarker, "policyBlocked")
    assertZeroDispatchBlocked(missing, "missing authorization")
    XCTAssertTrue(
      handoff.confirmationRequirements.joined().contains("standing authorization"),
      "handoff must name the missing standing-authorization carrier")

    // Authorization present but context (durable facts) absent: still policyBlocked —
    // the gate never guesses run counts or binding revisions.
    let missingContext = await decide(plan: plan, authorization: authorization, context: nil)
    guard case .policyBlocked = missingContext.outcome else {
      return XCTFail("authorization without durable context must stay policyBlocked")
    }
    assertZeroDispatchBlocked(missingContext, "missing context")

    // Ordinary CI with a fully valid authorization: never eligible for the unattended
    // path (REQ-FLASH-015: CI stays on contract/fake/simulated/plan-only).
    let ciDecision = await decide(
      authority: .ordinaryCI, plan: plan, authorization: authorization, context: context())
    guard case .policyBlocked = ciDecision.outcome else {
      return XCTFail("ordinary CI must stay policyBlocked even with a valid authorization")
    }
    assertZeroDispatchBlocked(ciDecision, "ordinary CI")

    print(
      "TEST-AC-FLASH-015-01 PASS standing_authorization_absent=policyBlocked "
        + "context_absent=policyBlocked ci_with_valid_authorization=policyBlocked dispatch=0")
  }

  // MARK: - AC-FLASH-015-02 pin/validity/readback deviations fail closed

  func testTEST_AC_FLASH_015_02_AnyAuthorizationDeviationYieldsZeroDispatch() async throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    let otherDigest = String(repeating: "d", count: 64)

    // Real-fault injection: mutate one field of the real JSON document per case.
    let mutations: [(expectedField: String, mutate: (inout [String: Any]) -> Void)] = [
      ("targetModel", { $0["target"] = ["model": "OTHER-BOARD (RK9999)",
                                        "serialSHA256": self.serialDigest,
                                        "bindingRevision": 3] }),
      ("targetBindingRevision", { $0["target"] = ["model": RockchipFlashProfile.targetDeviceModel,
                                                  "serialSHA256": self.serialDigest,
                                                  "bindingRevision": 4] }),
      ("firmwareArchiveSha256", { $0["firmwareArchiveSHA256"] = otherDigest }),
      ("transport", { $0["transport"] = "tcp" }),
      ("toolchainFingerprint", { $0["toolchainFingerprint"] = "rkdeveloptool-9.99@deadbeef" }),
      ("providerIdentity", { $0["providerIdentity"] = "arkdeck.some-other-provider" }),
      ("planDigestSha256", { $0["planDigestSHA256"] = otherDigest }),
      ("stepSetDigestSha256", { $0["stepSetDigestSHA256"] = otherDigest }),
    ]
    for (field, mutate) in mutations {
      var document = authorizationDictionary(plan: plan)
      mutate(&document)
      let mutated = try parse(document)
      let decision = await decide(plan: plan, authorization: mutated, context: context())
      guard case .blockedStandingAuthorizationMismatch(let fields) = decision.outcome else {
        return XCTFail("mutated \(field) must block, got \(decision.outcome)")
      }
      XCTAssertTrue(fields.contains(field), "expected \(field) in \(fields)")
      assertZeroDispatchBlocked(decision, field)
    }

    // An authorization minted for a different plan can never cover this one.
    let otherPlan = try provider.makePlan(
      mode: .execute, archiveValidation: .valid, planNonce: "other")
    let stale = try parse(authorizationDictionary(plan: otherPlan))
    let staleDecision = await decide(plan: plan, authorization: stale, context: context())
    guard case .blockedStandingAuthorizationMismatch(let staleFields) = staleDecision.outcome
    else {
      return XCTFail("an authorization for another plan must not authorize this plan")
    }
    XCTAssertTrue(staleFields.contains("stepSetDigestSha256"))
    assertZeroDispatchBlocked(staleDecision, "stale plan")

    // Validity window and run ceiling (real document, injected clock/ledger).
    let valid = try parse(authorizationDictionary(plan: plan))
    let expired = await decide(
      plan: plan, authorization: valid, context: context(currentTimestamp: "2026-09-01T00:00:00Z"))
    guard case .blockedStandingAuthorizationExpiredOrExhausted(let expiredReason) =
      expired.outcome
    else {
      return XCTFail("past validUntil must block")
    }
    XCTAssertTrue(expiredReason.contains("expired"))
    assertZeroDispatchBlocked(expired, "expired")

    var cappedDocument = authorizationDictionary(plan: plan)
    cappedDocument["maxRuns"] = 2
    let capped = try parse(cappedDocument)
    let exhausted = await decide(
      plan: plan, authorization: capped, context: context(priorRunCount: 2))
    guard case .blockedStandingAuthorizationExpiredOrExhausted(let exhaustedReason) =
      exhausted.outcome
    else {
      return XCTFail("run ceiling must block")
    }
    XCTAssertTrue(exhaustedReason.contains("runsExhausted"))
    assertZeroDispatchBlocked(exhausted, "exhausted")

    var badValidUntil = authorizationDictionary(plan: plan)
    badValidUntil["validUntil"] = "someday"
    let unparseable = await decide(
      plan: plan, authorization: try parse(badValidUntil), context: context())
    guard case .blockedStandingAuthorizationExpiredOrExhausted = unparseable.outcome else {
      return XCTFail("unparseable validUntil must fail closed")
    }
    assertZeroDispatchBlocked(unparseable, "unparseable validUntil")

    // Device identity readback: missing, wrong serial digest, wrong USB identity.
    let noReadback = await decide(
      plan: plan, authorization: valid,
      context: RockchipStandingAuthorizationContext(
        currentTimestamp: now, priorRunCount: 0, durableBindingRevision: 3,
        identityReadback: nil))
    guard case .blockedDeviceIdentityReadbackMismatch(let missingFields) = noReadback.outcome
    else {
      return XCTFail("missing readback must block")
    }
    XCTAssertEqual(missingFields, ["identityReadbackMissing"])
    assertZeroDispatchBlocked(noReadback, "missing readback")

    let wrongSerial = await decide(
      plan: plan, authorization: valid,
      context: context(
        readback: RockchipDeviceIdentityReadback(
          serialDigestSHA256: otherDigest, usbVendorID: 0x2207, usbProductID: 0x350a,
          readAtTimestamp: now)))
    guard case .blockedDeviceIdentityReadbackMismatch(let serialFields) = wrongSerial.outcome
    else {
      return XCTFail("serial digest mismatch must block")
    }
    XCTAssertTrue(serialFields.contains("serialDigestSha256"))
    assertZeroDispatchBlocked(wrongSerial, "serial mismatch")

    let wrongUSB = await decide(
      plan: plan, authorization: valid,
      context: context(
        readback: RockchipDeviceIdentityReadback(
          serialDigestSHA256: serialDigest, usbVendorID: 0x2207, usbProductID: 0x0001,
          readAtTimestamp: now)))
    guard case .blockedDeviceIdentityReadbackMismatch(let usbFields) = wrongUSB.outcome else {
      return XCTFail("usb identity mismatch must block")
    }
    XCTAssertTrue(usbFields.contains("usbIdentity"))
    assertZeroDispatchBlocked(wrongUSB, "usb mismatch")

    // Parse-boundary fail-closed: truncated JSON, unknown schema version, short digest.
    XCTAssertThrowsError(
      try RockchipStandingAuthorization.parse(Data("{\"schemaVersion\":".utf8)))
    var wrongSchema = authorizationDictionary(plan: plan)
    wrongSchema["schemaVersion"] = "0.9.0"
    XCTAssertThrowsError(try parse(wrongSchema)) { error in
      XCTAssertEqual(
        error as? RockchipStandingAuthorizationParseError, .unsupportedSchemaVersion("0.9.0"))
    }
    var shortDigest = authorizationDictionary(plan: plan)
    shortDigest["planDigestSHA256"] = String(repeating: "a", count: 63)
    XCTAssertThrowsError(try parse(shortDigest)) { error in
      XCTAssertEqual(
        error as? RockchipStandingAuthorizationParseError,
        .invalidDigest(field: "planDigestSHA256"))
    }

    print(
      "TEST-AC-FLASH-015-02 PASS sa_mismatch_fields=8 stale_plan=blocked expired=blocked "
        + "runs_exhausted=blocked unparseable_validity=blocked readback_missing=blocked "
        + "readback_serial=blocked readback_usb=blocked parse_faults=3 dispatch=0")
  }

  // MARK: - AC-FLASH-015-03 valid authorization authorizes unattended execution

  func testTEST_AC_FLASH_015_03_ValidAuthorizationAuthorizesUnattendedAgentExecution()
    async throws
  {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)

    // Uppercase digests in the carrier normalize on parse — comparison is not
    // case-brittle, and the parsed digests come back lowercase.
    var document = authorizationDictionary(plan: plan)
    document["firmwareArchiveSHA256"] = plan.archiveSHA256.uppercased()
    let authorization = try parse(document)
    XCTAssertEqual(authorization.firmwareArchiveSHA256, plan.archiveSHA256.lowercased())

    let decision = await decide(plan: plan, authorization: authorization, context: context())
    guard case .authorizedForUnattendedAgentExecution(let surface, let intent) =
      decision.outcome
    else {
      return XCTFail("pin-exact authorization must authorize, got \(decision.outcome)")
    }

    XCTAssertEqual(decision.jobMarker, "authorizedForUnattendedAgentExecution")
    XCTAssertEqual(
      decision.evidenceEligibility, .authorizedAgentRunMayProduceRealHardwareEvidence)
    XCTAssertEqual(decision.dispatchSnapshot.totalDispatchCount, 0)

    // The decision carries the authorization reference for the intent and v3 evidence.
    let ref = try XCTUnwrap(decision.authorizationRef)
    XCTAssertTrue(ref.contains("AUTH-2026-025-DAYU200-001"))
    XCTAssertTrue(ref.contains("PR #999"))

    // The command surface is the same closed design §0 sequence a human would run.
    XCTAssertEqual(surface.planDigestSHA256, plan.planDigestSHA256)
    XCTAssertFalse(surface.commandLines.isEmpty)

    // Durable intent binds run → authorization → plan → target before any dispatch.
    XCTAssertEqual(intent.authorizationRef, ref)
    XCTAssertEqual(intent.planDigestSHA256, plan.planDigestSHA256)
    XCTAssertEqual(intent.stepSetDigestSHA256, plan.stepSetDigestSHA256)
    XCTAssertEqual(intent.targetSerialDigestSHA256, serialDigest)
    XCTAssertEqual(intent.timestamp, now)
    XCTAssertTrue(intent.intentID.hasPrefix("unattended-flash-intent-"))

    // The intent persists through the session audit store with the reference intact.
    let record = try intent.auditRecord(sessionID: "session-1", jobID: "job-1")
    XCTAssertEqual(record.category, .intent)
    XCTAssertEqual(record.details["kind"], .string("unattendedFlashIntent"))
    XCTAssertEqual(record.details["authorizationRef"], .string(ref))
    XCTAssertEqual(record.details["planDigestSha256"], .string(plan.planDigestSHA256))

    // Evidence v3 field completeness for the executor face: everything the v3 record
    // requires from the gate is present and consistent (real capture is TASK-AIN-004).
    XCTAssertEqual(authorization.target.serialSHA256, serialDigest)
    XCTAssertFalse(authorization.approvedBy.isEmpty)

    print(
      "TEST-AC-FLASH-015-03 PASS executor=agent authorization_ref=present intent_durable="
        + "recorded readback=matched command_surface=closed dispatch=0 real_device=0")
  }
}
