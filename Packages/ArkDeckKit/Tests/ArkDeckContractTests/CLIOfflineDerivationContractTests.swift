import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// §6.2: `ui-dump inspect` and `hit-test` are deterministic local derivations.
///
/// The section asks two things of them, and both are about what the answer
/// says rather than how it is computed: record the parser identity/version and
/// the source Artifact digests, and never pass the derivation off as new
/// device evidence. A derivation that got the tree right and said neither
/// would still be wrong — a caller could not tell two answers apart, and could
/// not tell a picture of a past moment from a reading of the current one.
final class CLIOfflineDerivationContractTests: XCTestCase {

  private func source(_ name: String, _ digest: String) -> CLIOfflineDerivation.Source {
    CLIOfflineDerivation.Source(
      artifactID: "A-\(name)", name: name, mediaType: "application/json",
      sha256: digest, byteCount: 128)
  }

  func testProvenanceNamesTheParserAndEverySourceDigest() throws {
    let provenance = CLIOfflineDerivation.provenance(
      sources: [source("ui-tree.json", String(repeating: "a", count: 64))],
      observedFromUTC: "2026-08-31T10:00:00Z", observedToUTC: "2026-08-31T10:00:02Z")
    guard case .object(let fields) = provenance else {
      return XCTFail("provenance must be an object")
    }
    XCTAssertEqual(fields["parser"], .string(CLIOfflineDerivation.uiDumpParser))
    XCTAssertEqual(fields["parserVersion"], .string(CLIOfflineDerivation.uiDumpParserVersion))
    guard case .array(let sources)? = fields["sources"], case .object(let first)? = sources.first
    else { return XCTFail("the sources must be a list of objects") }
    XCTAssertEqual(first["sha256"], .string(String(repeating: "a", count: 64)))
    XCTAssertEqual(first["name"], .string("ui-tree.json"))
    XCTAssertNotNil(first["artifactId"])
    XCTAssertNotNil(first["byteCount"])
  }

  /// The field a machine branches on. §6.2 forbids a derived result from
  /// impersonating device evidence, and a consumer needs one key to check
  /// rather than a convention to remember — so this is the assertion that
  /// would fail if the word were ever dropped for being obvious.
  func testTheDerivationSaysItIsDerivedAndCarriesTheWindowItWasTakenIn() throws {
    guard case .object(let fields) = CLIOfflineDerivation.provenance(
      sources: [source("ui-tree.json", String(repeating: "b", count: 64))],
      observedFromUTC: "2026-08-31T10:00:00Z", observedToUTC: "2026-08-31T10:00:02Z")
    else { return XCTFail("provenance must be an object") }
    XCTAssertEqual(fields["kind"], .string("offlineDerived"))
    // The observation window, not the filing time: a reader deciding whether
    // this is a given moment needs when the device was being watched.
    XCTAssertEqual(fields["observedFromUtc"], .string("2026-08-31T10:00:00Z"))
    XCTAssertEqual(fields["observedToUtc"], .string("2026-08-31T10:00:02Z"))
  }

  /// A capture with no observation window says so rather than borrowing one.
  func testAnUnknownObservationWindowIsNullRatherThanTheCurrentTime() throws {
    guard case .object(let fields) = CLIOfflineDerivation.provenance(
      sources: [source("ui-tree.json", String(repeating: "c", count: 64))],
      observedFromUTC: nil, observedToUTC: nil)
    else { return XCTFail("provenance must be an object") }
    XCTAssertEqual(fields["observedFromUtc"], .null)
    XCTAssertEqual(fields["observedToUtc"], .null)
  }

  /// Two runs over the same job must produce the same document, so the source
  /// list is ordered by something stable rather than by whatever order the
  /// artifact index happened to return.
  func testTheSourceListIsOrderedSoTwoRunsAgreeByteForByte() throws {
    let a = source("ui-tree.json", String(repeating: "1", count: 64))
    let b = source("screenshot.png", String(repeating: "2", count: 64))
    let c = source("ui-dump.json", String(repeating: "3", count: 64))
    let forward = CLIOfflineDerivation.provenance(
      sources: [a, b, c], observedFromUTC: nil, observedToUTC: nil)
    let reversed = CLIOfflineDerivation.provenance(
      sources: [c, b, a], observedFromUTC: nil, observedToUTC: nil)
    XCTAssertEqual(
      try CLICanonicalJSON.canonicalString(forward),
      try CLICanonicalJSON.canonicalString(reversed))
  }

  /// §6.2's honesty rule at the level below the document: a capture whose
  /// coordinate mapping the provider never confirmed is still inspectable, and
  /// must not be hit-tested. `ViewerHitTesting` already refuses; this pins
  /// that the refusal is a property of the capture rather than of the caller
  /// remembering to check.
  func testHitTestingRefusesACaptureWhoseCoordinatesWereNeverVerified() {
    let capture = ViewerCapture(
      screenshotData: Data(), screenshotWidth: 100, screenshotHeight: 100,
      roots: [], nodes: [], rawDumpDocument: nil,
      identity: ViewerCaptureIdentity(
        jobID: "J-1", targetID: "T-1", bindingRevision: 1,
        capturedAtUTC: "2026-08-31T10:00:00Z"),
      coordinatesAreVerified: false)
    XCTAssertNil(
      ViewerHitTesting.node(in: capture, x: 10, y: 10),
      "an unverified coordinate mapping cannot resolve a point to a node")

    guard case .object(let encoded) = CLIOfflineDerivation.encode(capture: capture) else {
      return XCTFail("the capture projection must be an object")
    }
    XCTAssertEqual(
      encoded["coordinatesAreVerified"], .bool(false),
      "the flag is published so a caller can see why a hit-test would refuse")
  }

  /// The registry half: these leaves reach the Runtime for bytes but submit no
  /// operation. A Catalog mapping would put a deterministic local computation
  /// inside Catalog + Job/WAL, which is where §5.1 puts device work instead.
  func testTheDerivationLeavesSubmitNoOperation() {
    for command in ["ui-dump.inspect", "ui-dump.hit-test"] {
      let leaf = CLICommandRegistry.allLeaves()
        .first { $0.leaf.canonicalCommand == command }?.leaf
      XCTAssertNotNil(leaf, command)
      XCTAssertNil(leaf?.catalogOperation, "\(command) must not map to an operation")
      XCTAssertEqual(leaf?.connectsToRuntime, true, "\(command) reads published bytes")
      XCTAssertTrue(leaf?.outputModes.contains(.json) == true, command)
    }
  }
}
