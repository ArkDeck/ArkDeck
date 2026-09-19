import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

final class OverviewCapabilityApplicationFacadeContractTests: XCTestCase {
  /// Stands in for the Debug workspace's window-inventory runner, which the
  /// App composes from ArkDeckWorkflows: it records each Job it is asked to
  /// run and answers one terminal result.
  private actor WindowInventoryRuns: OverviewWindowInventoryJobRunning {
    private let result: OverviewWindowInventoryJobResult
    private var runs: [String] = []

    init(_ result: OverviewWindowInventoryJobResult = .failed("no Job in this test")) {
      self.result = result
    }

    func runWindowInventory(
      targetID: String, bindingRevision: Int
    ) -> OverviewWindowInventoryJobResult {
      runs.append("\(targetID)@\(bindingRevision)")
      return result
    }

    func recordedRuns() -> [String] { runs }
  }

  private struct Call: Equatable, Sendable {
    let method: String
    let params: [String: JSONValue]?
  }

  /// Answers each read by method. `operation.list` and `target.list` are
  /// issued concurrently, so their order is not part of the contract.
  private actor Reads {
    private let answers: [String: JSONValue]
    private var calls: [Call] = []

    init(_ answers: [String: JSONValue]) { self.answers = answers }

    func request(
      _ method: String, _ params: [String: JSONValue]?
    ) -> Result<Data, OverviewCapabilityReadFailure> {
      calls.append(Call(method: method, params: params))
      guard let result = answers[method],
        let data = try? CanonicalJSONEncoders.canonical().encode(
          JSONValue.object(["id": .string("fixture"), "ok": .bool(true), "result": result]))
      else { return .failure(.transport("unexpected request \(method)")) }
      return .success(data)
    }

    func recordedCalls() -> [Call] { calls.sorted { $0.method < $1.method } }
  }

  private static func reads(targets: [(String, Int)]) -> Reads {
    Reads([
      "operation.list": .array([
        .object([
          "reference": .string(ArkForgeFlashOperation.canonicalReference),
          "availability": .string("unavailable"),
          "reasons": .array([.string("provider arkforge is not registered")]),
        ])
      ]),
      "target.list": .array(
        targets.map {
          .object(["targetId": .string($0.0), "bindingRevision": .integer(Int64($0.1))])
        }),
      "trace.probe": .object([
        "targetId": .string("target-a"),
        "bindingRevision": .integer(7),
        "supportedTags": .array([.string("app"), .string("ability")]),
        "tools": .array([
          .object([
            "tool": .string("hitrace"), "disposition": .string("captureEligible"),
            "family": .string("hitrace-v1"),
            "rawHelpSha256": .string(String(repeating: "0123456789abcdef", count: 4)),
            "detail": .null,
          ]),
          .object([
            "tool": .string("bytrace"), "disposition": .string("notAPublishedVerdict"),
            "family": .null, "rawHelpSha256": .null, "detail": .null,
          ]),
        ]),
      ]),
    ])
  }

  func testFixtureProjectsTheFourActualCapabilityRows() async {
    let windowInventory = WindowInventoryRuns()
    let provider = OverviewCapabilityApplicationFacade.make(
      windowInventory: windowInventory,
      arguments: ["ArkDeck", "--ui-test-hdc-diagnostics"])
    let presentation = await provider.refresh(targetID: nil)

    XCTAssertEqual(presentation.targetID, "target-fixture-dayu200")
    XCTAssertEqual(
      presentation.items.map(\.id),
      ["hidumper", "hitrace", "bytrace", "rockusb-flash"])
    XCTAssertEqual(presentation.items.first(where: { $0.id == "hitrace" })?.state, .available)
    XCTAssertEqual(presentation.items.first(where: { $0.id == "bytrace" })?.state, .unknown)
    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["target-fixture-dayu200"])
    // Presentation values only: the fixture never submits a Job.
    let runs = await windowInventory.recordedRuns()
    XCTAssertEqual(runs, [])
  }

  /// A target the operator did not choose is never described. The fixture
  /// stands in for the production rule: an unknown selection reports what is
  /// adopted instead of quietly answering about something else.
  func testAnUnadoptedSelectionIsRefusedRatherThanSubstituted() async {
    let provider = OverviewCapabilityApplicationFacade.make(
      windowInventory: WindowInventoryRuns(),
      arguments: ["ArkDeck", "--ui-test-hdc-diagnostics"])
    let presentation = await provider.refresh(targetID: "some-other-target")

    XCTAssertNil(presentation.targetID)
    XCTAssertTrue(presentation.items.isEmpty)
    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["target-fixture-dayu200"])
    XCTAssertEqual(
      presentation.failure, "The selected target is no longer adopted: some-other-target")
  }

  /// The production provider reads its own facts and hands only the resolved
  /// target and binding revision to the window-inventory runner. The hidumper
  /// row is available only for a succeeded Job whose outcome is known.
  func testProductionReadsResolveTheTargetBeforeItsWindowInventoryJobRuns() async {
    let cases: [(OverviewWindowInventoryJobResult, OverviewCapabilityState, String)] = [
      (
        .completed(jobID: "job-window", state: "succeeded", outcomeUnknown: false),
        .available, "debug.template@1 Job succeeded · job-window"
      ),
      (
        .completed(jobID: "job-window", state: "succeeded", outcomeUnknown: true),
        .unknown, "debug.template@1 Job succeeded · job-window"
      ),
      (
        .completed(jobID: "job-window", state: "failed", outcomeUnknown: false),
        .unknown, "debug.template@1 Job failed · job-window"
      ),
      (.failed("Runtime refused the request: busy"), .unknown, "Runtime refused the request: busy"),
    ]
    for (result, state, evidence) in cases {
      let reads = Self.reads(targets: [("target-a", 7)])
      let windowInventory = WindowInventoryRuns(result)
      let provider = OverviewCapabilityProductionProvider(
        windowInventory: windowInventory, request: { await reads.request($0, $1) })

      let presentation = await provider.refresh(targetID: nil)

      let calls = await reads.recordedCalls()
      XCTAssertEqual(
        calls,
        [
          Call(method: "operation.list", params: nil),
          Call(method: "target.list", params: nil),
          Call(method: "trace.probe", params: ["targetId": .string("target-a")]),
        ])
      let runs = await windowInventory.recordedRuns()
      XCTAssertEqual(runs, ["target-a@7"])
      XCTAssertEqual(presentation.targetID, "target-a")
      XCTAssertEqual(presentation.bindingRevision, 7)
      XCTAssertNil(presentation.failure)
      XCTAssertEqual(
        presentation.items,
        [
          OverviewCapabilityItemPresentation(
            id: "hidumper", name: "hidumper", state: state, evidence: evidence),
          OverviewCapabilityItemPresentation(
            id: "hitrace", name: "hitrace", state: .available,
            evidence: "hitrace-v1 · tags × 2 · help sha256 0123456789ab…"),
          OverviewCapabilityItemPresentation(
            id: "bytrace", name: "bytrace", state: .unknown,
            evidence: "Required probe result was omitted"),
          OverviewCapabilityItemPresentation(
            id: "rockusb-flash", name: "RockUSB Flash", state: .unavailable,
            evidence: "provider arkforge is not registered"),
        ])
    }
  }

  /// Without a choice between several adopted targets nothing is probed and
  /// no Job is submitted; a chosen target is probed at its own revision.
  func testSeveralAdoptedTargetsAreNeitherProbedNorRunWithoutAChoice() async {
    let reads = Self.reads(targets: [("target-a", 7), ("target-b", 3)])
    let windowInventory = WindowInventoryRuns()
    let provider = OverviewCapabilityProductionProvider(
      windowInventory: windowInventory, request: { await reads.request($0, $1) })

    let unchosen = await provider.refresh(targetID: nil)

    XCTAssertEqual(
      unchosen.failure, "2 adopted targets are available; choose which one to describe")
    XCTAssertNil(unchosen.targetID)
    XCTAssertEqual(unchosen.items.map(\.id), ["rockusb-flash"])
    XCTAssertEqual(unchosen.adoptedTargets.map(\.id), ["target-a", "target-b"])
    let unchosenCalls = await reads.recordedCalls()
    XCTAssertEqual(unchosenCalls.map(\.method), ["operation.list", "target.list"])
    let unchosenRuns = await windowInventory.recordedRuns()
    XCTAssertEqual(unchosenRuns, [])

    let chosen = await provider.refresh(targetID: "target-b")

    XCTAssertEqual(chosen.targetID, "target-b")
    XCTAssertEqual(chosen.bindingRevision, 3)
    let chosenCalls = await reads.recordedCalls()
    XCTAssertEqual(
      chosenCalls.filter { $0.method == "trace.probe" },
      [Call(method: "trace.probe", params: ["targetId": .string("target-b")])])
    let chosenRuns = await windowInventory.recordedRuns()
    XCTAssertEqual(chosenRuns, ["target-b@3"])
    // Facts that describe another target are refused, and the refusal reads
    // exactly as it did through the Debug workspace's read transport.
    XCTAssertEqual(
      chosen.items.filter { ["hitrace", "bytrace"].contains($0.id) }.map(\.evidence),
      Array(repeating: #"transport("Runtime returned mismatched Trace facts")"#, count: 2))
  }

  func testOverviewOnlineProjectionOmitsOfflineAndStaleAdoptedTargets() {
    let capabilities = OverviewCapabilityMatrixPresentation(
      targetID: "target-offline", bindingRevision: 2,
      items: [
        OverviewCapabilityItemPresentation(
          id: "hidumper", name: "hidumper", state: .available, evidence: "old target"),
        OverviewCapabilityItemPresentation(
          id: "rockusb-flash", name: "RockUSB Flash", state: .available,
          evidence: "catalog"),
      ],
      adoptedTargets: [
        OverviewCapabilityTarget(id: "target-online", bindingRevision: 4),
        OverviewCapabilityTarget(id: "target-offline", bindingRevision: 2),
        OverviewCapabilityTarget(id: "target-stale", bindingRevision: 1),
      ])
    let devices = DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "online", state: "Connected",
          adoptedTargetID: "target-online", bindingRevision: 4),
        DeviceCandidatePresentation(
          connectKey: "offline", state: "Offline",
          adoptedTargetID: "target-offline", bindingRevision: 2),
        DeviceCandidatePresentation(
          connectKey: "stale", state: "Connected",
          adoptedTargetID: "target-stale", bindingRevision: 1,
          stateObservationHealth: .stale),
      ])

    let presentation = OverviewOnlineTargetProjection.presentation(
      from: capabilities, devices: devices, preferredTargetID: "target-offline")

    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["target-online"])
    XCTAssertEqual(presentation.targetID, "target-online")
    XCTAssertEqual(presentation.bindingRevision, 4)
    XCTAssertEqual(presentation.items.map(\.id), ["rockusb-flash"])
  }

  /// The defect this replaced: the matrix bound `targets.first`, so on a host
  /// with several adopted devices it described an arbitrary one and the page
  /// could not say whose capabilities the reader was looking at.
  func testSeveralAdoptedTargetsAreReportedInsteadOfProbingAnArbitraryOne() throws {
    let source = try facadeSource()

    XCTAssertFalse(
      source.contains("targets.first"),
      "resolving a target by position is the defect, not an implementation detail")
    XCTAssertTrue(source.contains("adopted targets are available; choose which one"))
    XCTAssertTrue(source.contains("adoptedTargets: adopted"))
  }

  func testProductionSourceUsesIndependentFactsAndThePublishedFlashOperation() throws {
    let source = try facadeSource()

    XCTAssertTrue(source.contains("request(\"trace.probe\""))
    XCTAssertTrue(source.contains("windowInventory.runWindowInventory("))
    XCTAssertFalse(source.contains("\"debug.template.run\""))
    XCTAssertTrue(source.contains("debug.template@1 Job succeeded"))
    XCTAssertTrue(source.contains("ArkForgeFlashOperation.canonicalReference"))
    XCTAssertFalse(source.contains("flash.dayu200"))
    XCTAssertFalse(source.contains("flashd"))
    XCTAssertTrue(source.contains("OverviewTraceToolDisposition(rawValue: raw)"))
    // ClientKit reads; the Job request stays with the Debug workspace's runner.
    for forbidden in ["\"job.submit\"", "\"job.run\"", "RuntimeOperationRequest"] {
      XCTAssertFalse(source.contains(forbidden), forbidden)
    }
    for forbiddenImport in [
      "ArkDeckWorkflows", "ArkDeckRuntime", "ArkDeckOpenHarmony", "ArkDeckStorage",
    ] {
      XCTAssertFalse(source.contains("import \(forbiddenImport)"), forbiddenImport)
    }
  }

  private func facadeSource() throws -> String {
    try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckClientKit/OverviewCapabilityApplicationFacade.swift"),
      encoding: .utf8)
  }
}
