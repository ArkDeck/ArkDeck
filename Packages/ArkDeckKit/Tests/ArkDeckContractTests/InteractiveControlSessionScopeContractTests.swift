import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// The control-session authorization envelope (TASK-IDC-002 stage 2).
///
/// A pointer gesture's authorized subject is the session — target, binding and
/// gesture kind — not the coordinate. The scope fingerprint hashes `inputs`
/// and the materialized plan digest, and both move with every coordinate, so
/// per-gesture scoping would mint one permanent capability record per screen
/// position into a store that is rewritten whole on each issue and consume
/// (measured: 318 records / 1.29 MB, see the change's evidence).
final class InteractiveControlSessionScopeContractTests: XCTestCase {
  private func descriptor(_ reference: String) throws -> CatalogOperationDescriptor {
    try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
  }

  private func fingerprint(
    _ descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    planDigest: String
  ) -> String {
    let subject = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: descriptor, inputs: inputs, planDigest: planDigest)
    // The identity that decides which capability record a job lands on.
    let encoder = CanonicalJSONEncoders.canonical()
    let encoded = (try? encoder.encode(subject.inputs)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    return "\(descriptor.reference)|\(subject.planDigest ?? "-")|\(encoded ?? "?")"
  }

  func testEveryPointerCoordinateSharesOneAuthorizationSubject() throws {
    let tap = try descriptor("input.tap@1")
    // Two taps a user sends at different screen positions, each with the plan
    // digest that materialization would produce for it.
    let first = fingerprint(
      tap, inputs: ["x": .integer(640), "y": .integer(1500)],
      planDigest: String(repeating: "a", count: 64))
    let second = fingerprint(
      tap, inputs: ["x": .integer(120), "y": .integer(300)],
      planDigest: String(repeating: "b", count: 64))
    XCTAssertEqual(
      first, second,
      "two taps at different coordinates must authorize against one session record")
  }

  func testTheDisplayStaysPartOfTheAuthorizedSubject() throws {
    let tap = try descriptor("input.tap@1")
    let defaultDisplay = fingerprint(
      tap, inputs: ["x": .integer(1), "y": .integer(2)],
      planDigest: String(repeating: "a", count: 64))
    let secondDisplay = fingerprint(
      tap, inputs: ["x": .integer(1), "y": .integer(2), "displayId": .integer(2)],
      planDigest: String(repeating: "a", count: 64))
    XCTAssertNotEqual(
      defaultDisplay, secondDisplay,
      "a gesture on another display is a different subject, not the same session")
  }

  func testEachGestureKindKeepsItsOwnEnvelope() throws {
    let references = ["input.tap@1", "input.long-press@1", "input.swipe@1"]
    var subjects: Set<String> = []
    for reference in references {
      subjects.insert(
        fingerprint(
          try descriptor(reference), inputs: ["x": .integer(5), "y": .integer(5)],
          planDigest: String(repeating: "c", count: 64)))
    }
    XCTAssertEqual(
      subjects.count, references.count,
      "tap, long-press and swipe must remain separately authorized")
  }

  func testTheProjectionIsSymmetricAcrossIssueAndConsume() throws {
    // Issue time carries the request's inputs; consume time re-reads them from
    // the durable record. If the projection were applied at only one site the
    // consume would look up an ID the issue never wrote.
    let swipe = try descriptor("input.swipe@1")
    let inputs: [String: JSONValue] = [
      "fromX": .integer(640), "fromY": .integer(2000),
      "toX": .integer(640), "toY": .integer(1000), "durationMs": .integer(500),
    ]
    let atIssue = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: swipe, inputs: inputs, planDigest: String(repeating: "d", count: 64))
    let atConsume = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: swipe, inputs: inputs, planDigest: String(repeating: "d", count: 64))
    XCTAssertEqual(atIssue.inputs, atConsume.inputs)
    XCTAssertEqual(atIssue.planDigest, atConsume.planDigest)
    XCTAssertNil(
      atIssue.planDigest,
      "the plan digest moves with the coordinates, so it cannot pin the session subject")
    XCTAssertTrue(
      atIssue.inputs.isEmpty,
      "no coordinate or duration may survive into the authorized subject")
  }

  func testOnlyThePublishedInputOperationsAreSessionScoped() throws {
    XCTAssertEqual(
      RuntimeJobEngine.sessionScopedInputOperations,
      ["input.tap@1", "input.long-press@1", "input.swipe@1"])
    // A neighbouring device mutation must keep its exact-input subject: its
    // authorization is meant to name the precise rule it creates.
    let portForward = try descriptor("port-forward.create@1")
    let inputs: [String: JSONValue] = [
      "direction": .string("forward"), "localPort": .integer(2345),
      "remotePort": .integer(3456),
    ]
    let subject = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: portForward, inputs: inputs,
      planDigest: String(repeating: "e", count: 64))
    XCTAssertEqual(subject.inputs, inputs)
    XCTAssertEqual(subject.planDigest, String(repeating: "e", count: 64))
  }

  func testTheSessionEnvelopeIsBoundedInTimeAndUses() {
    XCTAssertEqual(
      RuntimeJobEngine.sessionScopedInputLifetime, 60 * 60,
      "a control session authorizes one sitting, not the standing thirty days")
    XCTAssertEqual(RuntimeJobEngine.sessionScopedInputMaximumUses, 2_000)
    XCTAssertLessThan(
      RuntimeJobEngine.sessionScopedInputMaximumUses, 10_000,
      "the session budget must be tighter than the standing default it replaces")
  }
}
