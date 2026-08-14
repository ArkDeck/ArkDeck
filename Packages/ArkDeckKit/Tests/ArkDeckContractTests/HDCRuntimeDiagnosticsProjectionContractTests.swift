import Foundation
import XCTest

@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class HDCRuntimeDiagnosticsProjectionContractTests: XCTestCase {
  func testConnectedRuntimeProjectionReplacesLocalDiscoveryWithoutExposingPathOrLifecycle() throws {
    let projected = HDCRuntimeDiagnosticsResponseDecoding.overlay(
      presentation: basePresentation(),
      statusResponse: .success(try statusResponse()),
      candidateResponse: .success(try candidateResponse(states: ["Connected"])))

    XCTAssertTrue(projected.isRuntimeManaged)
    XCTAssertEqual(projected.absolutePath, "not exposed by Runtime")
    XCTAssertEqual(projected.source, "ArkDeck Runtime")
    XCTAssertEqual(projected.hash, String(repeating: "a", count: 64))
    XCTAssertEqual(projected.platformTrust, "descriptor-bound SHA-256 verified by Runtime")
    XCTAssertEqual(projected.clientVersion, "3.2.0f")
    XCTAssertEqual(projected.serverVersion, "3.2.0f")
    XCTAssertEqual(projected.daemonVersion, "Runtime protocol 1.0.0")
    XCTAssertEqual(projected.endpoint, "127.0.0.1:8710")
    XCTAssertEqual(projected.endpointSource, .default)
    XCTAssertEqual(projected.serverHealth, .healthy)
    XCTAssertEqual(projected.ownership, .arkDeckManaged)
    XCTAssertEqual(projected.authorization, .ready)
    XCTAssertEqual(projected.channelProtection, .unverifiedAssumeUnprotected)
    XCTAssertNil(projected.tcpUnprotectedWarning)
    XCTAssertNil(projected.keyAccessError)
    XCTAssertEqual(projected.subserverCapability, .unsupported)
    XCTAssertEqual(
      projected.lifecycleRecovery,
      .unavailable(reason: "ArkDeck Runtime owns the managed HDC server lifecycle"))
    XCTAssertEqual(projected.deviceEvents, basePresentation().deviceEvents)
  }

  func testRuntimeDeviceStatesMapToClosedAuthorizationVocabulary() throws {
    func authorization(_ states: [String]) throws -> HDCAuthorizationState {
      let presentation = HDCRuntimeDiagnosticsResponseDecoding.overlay(
        presentation: basePresentation(),
        statusResponse: .success(try statusResponse()),
        candidateResponse: .success(try candidateResponse(states: states)))
      return presentation.authorization
    }

    XCTAssertEqual(try authorization(["Unauthorized"]), .unauthorizedWaitingForTrust)
    XCTAssertEqual(
      try authorization(["Offline"]),
      .unavailable(reason: "HDC reported the target offline"))
    XCTAssertEqual(
      try authorization([]),
      .unavailable(reason: "No HDC device candidate is visible"))
    XCTAssertEqual(
      try authorization(["FutureState"]),
      .unavailable(reason: "Runtime returned an unrecognized HDC device state"))

    let unreadable = HDCRuntimeDiagnosticsResponseDecoding.overlay(
      presentation: basePresentation(),
      statusResponse: .success(try statusResponse()),
      candidateResponse: .failure(.transport("fixture")))
    XCTAssertEqual(
      unreadable.authorization,
      .unavailable(reason: "Runtime device authorization could not be read"))
  }

  func testUnverifiedOrNonLoopbackStatusCannotOverwriteLocalPresentation() throws {
    let base = basePresentation()
    for mutation in [
      ["endpoint": "192.0.2.10:8710"],
      ["serverVersion": "3.2.0d"],
      ["toolSha256": "short"],
      ["availability": "unavailable"],
      ["ownership": "external"],
    ] {
      var status = validStatus()
      for (key, value) in mutation { status[key] = value }
      let projected = HDCRuntimeDiagnosticsResponseDecoding.overlay(
        presentation: base,
        statusResponse: .success(try response(result: status)),
        candidateResponse: .success(try candidateResponse(states: ["Connected"])))
      XCTAssertEqual(projected, base, "mutation \(mutation) must fail closed")
      XCTAssertFalse(projected.isRuntimeManaged)
    }
  }

  func testProductionPrefersRuntimeAndViewsHideLocalExecutableControls() throws {
    let workflows = try repositorySource(
      "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift")
    let productionStart = try XCTUnwrap(
      workflows.range(of: "private actor HDCProductionApplicationDiagnostics"))
    let refreshStart = try XCTUnwrap(
      workflows.range(
        of: "func refresh() async",
        range: productionStart.upperBound..<workflows.endIndex))
    let requestStart = try XCTUnwrap(
      workflows.range(
        of: "func requestRecoveryImpactPreview() async",
        range: refreshStart.upperBound..<workflows.endIndex))
    let refresh = String(workflows[refreshStart.lowerBound..<requestStart.lowerBound])
    let runtimeCheck = try XCTUnwrap(refresh.range(of: "runtimeManagedPresentation()"))
    let localBootstrap = try XCTUnwrap(refresh.range(of: "attachSessionIfConfigured()"))
    XCTAssertLessThan(runtimeCheck.lowerBound, localBootstrap.lowerBound)
    XCTAssertTrue(
      workflows.contains("--ui-test-hdc-local-production-presentation"),
      "the signed UI regression must be able to inspect local production composition "
        + "without depending on ambient Runtime state")
    XCTAssertTrue(
      workflows.contains("guard runtimeProjectionEnabled else { return presentation }"))

    let overview = try repositorySource("ArkDeckApp/Features/HDC/HDCStatusView.swift")
    let settings = try repositorySource("ArkDeckApp/Features/Settings/SettingsRootView.swift")
    XCTAssertTrue(
      overview.contains(
        "onSelectUserConfiguredExecutable != nil && !presentation.isRuntimeManaged"))
    XCTAssertTrue(settings.contains("if !presentation.isRuntimeManaged"))
  }

  private func basePresentation() -> HDCDiagnosticsPresentation {
    HDCDiagnosticsPresentation(
      absolutePath: "/fixture/local/hdc",
      source: "localDiscovery",
      hash: "local-hash",
      platformTrust: "unknown",
      clientVersion: "unknown",
      serverVersion: "unknown",
      daemonVersion: "unknown",
      endpoint: "127.0.0.1:8710",
      serverHealth: .unknown,
      generation: "unknown",
      ownership: .unknown,
      authorization: .unavailable(reason: "local discovery unavailable"),
      channelProtection: .unverifiedAssumeUnprotected,
      subserverCapability: .unknown(reason: "local discovery unavailable"),
      lifecycleRecovery: .unavailable(reason: "local discovery unavailable"))
  }

  private func statusResponse() throws -> Data {
    try response(result: validStatus())
  }

  private func validStatus() -> [String: Any] {
    [
      "availability": "ready",
      "source": "runtimeManaged",
      "toolSha256": String(repeating: "a", count: 64),
      "clientVersion": "3.2.0f",
      "serverVersion": "3.2.0f",
      "endpoint": "127.0.0.1:8710",
      "endpointSource": "default",
      "serverHealth": "healthy",
      "ownership": "arkDeckManaged",
      "protocolVersion": "1.0.0",
    ]
  }

  private func candidateResponse(states: [String]) throws -> Data {
    try response(
      result: states.enumerated().map { index, state in
        [
          "connectKey": "must-not-enter-presentation-\(index)",
          "state": state,
          "adoptedTargetId": NSNull(),
          "bindingRevision": NSNull(),
        ] as [String: Any]
      })
  }

  private func response(result: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
  }

  private func repositorySource(_ path: String) throws -> String {
    var root = URL(filePath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try String(contentsOf: root.appending(path: path), encoding: .utf8)
  }
}
