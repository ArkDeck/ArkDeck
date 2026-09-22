import Foundation
import XCTest
@testable import ArkDeckClientKit

final class HDCClientDiagnosticsTests: XCTestCase {
  private func response(_ changes: [String: Any] = [:]) throws -> Data {
    var status: [String: Any] = [
      "schemaVersion": "arkdeck.runtime-hdc-status/1", "availability": "available",
      "executableSHA256": String(repeating: "a", count: 64), "endpoint": "127.0.0.1:8710",
      "endpointSource": "default", "generation": "7", "ownership": "arkDeckManaged",
      "serverHealth": "healthy", "clientVersion": "3.2.0f", "serverVersion": "3.2.0f",
      "daemonVersion": "0.1.0", "newDispatchCount": 0,
    ]
    status.merge(changes) { _, value in value }
    return try JSONSerialization.data(withJSONObject: ["ok": true, "result": status])
  }

  private func observation(stale: Bool = false) -> DeviceListPresentation {
    DeviceListPresentation(
      availability: .available,
      candidates: [.init(connectKey: "fixture", state: "Connected", adoptedTargetID: "target", bindingRevision: 1,
        stateObservationHealth: stale ? .stale : .current)])
  }

  private actor Replies {
    var responses: [RuntimeXPCRequestTransport.ResultValue]
    var calls: [String] = []
    init(_ responses: [RuntimeXPCRequestTransport.ResultValue]) { self.responses = responses }
    func send(_ method: String) -> RuntimeXPCRequestTransport.ResultValue {
      calls.append(method)
      guard !responses.isEmpty else { return .failure(.refused("unexpected request")) }
      return responses.removeFirst()
    }
  }

  func testProductionRefreshUsesOnlyRuntimeAndDoesNotInventMissingObservations() async throws {
    let replies = Replies([.success(try response())])
    let provider = HDCClientDiagnosticsProvider(send: { await replies.send($0) })
    let status = await provider.refresh(deviceObservation: observation())
    XCTAssertTrue(status.isRuntimeManaged)
    XCTAssertEqual(status.serverHealth, .healthy)
    XCTAssertEqual(status.authorization, .ready)
    XCTAssertEqual(status.generation, "7")
    XCTAssertEqual(status.ownership, .arkDeckManaged)
    XCTAssertNil(status.loadFailure)
    XCTAssertNil(status.automaticLifecycleDispatchCount)
    XCTAssertNil(status.automaticSubserverDispatchCount)
    XCTAssertFalse(status.deviceEventsAvailable)
    XCTAssertNil(status.ownershipBasis)
    XCTAssertEqual(status.channelProtection, .unverifiedAssumeUnprotected)
    XCTAssertFalse(provider.lifecycleDispatchIsProductionComposed)
    let calls = await replies.calls
    XCTAssertEqual(calls, ["runtime.hdc.status"])
  }

  func testDisconnectClearsPreviousFactsWithoutFallbackOrRetry() async throws {
    let replies = Replies([.success(try response()), .failure(.unavailable("connection interrupted"))])
    let provider = HDCClientDiagnosticsProvider(send: { await replies.send($0) })
    _ = await provider.refresh(deviceObservation: observation())
    let failed = await provider.refresh(deviceObservation: observation())
    XCTAssertTrue(failed.isRuntimeManaged)
    XCTAssertEqual(failed.serverHealth, .unknown)
    XCTAssertEqual(failed.ownership, .unknown)
    XCTAssertEqual(failed.generation, "unknown")
    XCTAssertTrue(try XCTUnwrap(failed.loadFailure).contains("connection interrupted"))
    XCTAssertNotEqual(failed.authorization, .ready)
    let calls = await replies.calls
    XCTAssertEqual(calls, ["runtime.hdc.status", "runtime.hdc.status"])
  }

  func testUnavailableAndMalformedFactsCannotPromoteAuthorizationOrHealth() throws {
    for change: [String: Any] in [
      ["availability": "unavailable", "reasonCode": "hdc.notConfigured"],
      ["availability": "unknown", "reasonCode": "hdc.identityObservationTimedOut"],
      ["schemaVersion": "future"], ["executableSHA256": "short"],
      ["endpoint": "192.0.2.1:8710"], ["endpoint": "127.0.0.1:0"],
      ["generation": "01"], ["generation": "0"], ["ownership": "future"],
      ["serverHealth": "future"], ["endpointSource": "future"],
    ] {
      let status = HDCClientDiagnosticsDecoding.presentation(.success(try response(change)), deviceObservation: observation())
      XCTAssertNotNil(status.loadFailure, "\(change)")
      XCTAssertEqual(status.serverHealth, .unknown)
      XCTAssertNotEqual(status.authorization, .ready)
      XCTAssertNil(status.lifecycleImpactPreview)
    }
    let missing = HDCClientDiagnosticsDecoding.presentation(
      .success(try response(["availability": "unavailable", "reasonCode": "hdc.notConfigured"])), deviceObservation: observation())
    XCTAssertTrue(try XCTUnwrap(missing.loadFailure).contains("hdc.notConfigured"))
  }

  func testRuntimeRefusalPreservesReasonAndClearsFacts() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "ok": false, "error": ["code": "methodNotAllowlisted", "message": "App method unavailable"],
    ])
    let status = HDCClientDiagnosticsDecoding.presentation(.success(data), deviceObservation: observation())
    XCTAssertTrue(try XCTUnwrap(status.loadFailure).contains("methodNotAllowlisted"))
    XCTAssertTrue(try XCTUnwrap(status.loadFailure).contains("App method unavailable"))
    XCTAssertEqual(status.serverHealth, .unknown)
    XCTAssertNotEqual(status.authorization, .ready)
  }

  func testTimeoutRemainsUnknownAndStaleDeviceDoesNotShowReady() throws {
    let timedOut = HDCClientDiagnosticsDecoding.presentation(.failure(.timedOut), deviceObservation: observation())
    XCTAssertNotNil(timedOut.loadFailure)
    XCTAssertEqual(timedOut.serverHealth, .unknown)
    let stale = HDCClientDiagnosticsDecoding.presentation(.success(try response()), deviceObservation: observation(stale: true))
    XCTAssertEqual(stale.serverHealth, .healthy)
    XCTAssertNotEqual(stale.authorization, .ready)
  }

  func testLegacyLocalFlagsDoNotSelectHostExecutionOrFixture() {
    let production = HDCClientDiagnosticsApplicationFacade.make(arguments: [
      "ArkDeck", "--ui-test-hdc-local-production-presentation", "--ui-test-reset-hdc-selection",
    ])
    XCTAssertTrue(production is HDCClientDiagnosticsProvider)
    XCTAssertFalse(production.lifecycleDispatchIsProductionComposed)
    XCTAssertTrue(HDCClientDiagnosticsApplicationFacade.make(arguments: ["--ui-test-hdc-diagnostics"]) is HDCClientDiagnosticsFixture)
  }

  func testUnavailableRecoveryNeverCreatesConfirmationOrDispatch() async {
    let replies = Replies([])
    let provider = HDCClientDiagnosticsProvider(send: { await replies.send($0) })
    for status in [await provider.requestRecoveryImpactPreview(), await provider.confirmRecoveryImpactPreview(),
      await provider.dispatchConfirmedRecovery()] {
      guard case .unavailable = status.lifecycleRecovery else { return XCTFail("no App approval route is composed") }
      XCTAssertNil(status.lifecycleImpactPreview)
    }
    do {
      _ = try await provider.selectUserConfiguredExecutable(URL(filePath: "/tmp/unregistered-hdc"))
      XCTFail("App must not register a local execution path")
    } catch {}
    let calls = await replies.calls
    XCTAssertTrue(calls.isEmpty)
  }

  func testExplicitFixtureRetainsDisplayStatesWithoutAuthority() async {
    let fixture = HDCClientDiagnosticsFixture(arguments: ["--ui-test-hdc-diagnostics", "--ui-test-hdc-channel-verified"])
    let current = await fixture.refresh(deviceObservation: .loading)
    XCTAssertFalse(current.isRuntimeManaged)
    XCTAssertTrue(current.deviceEventsAvailable)
    XCTAssertEqual(current.automaticLifecycleDispatchCount, 0)
    let preview = await fixture.requestRecoveryImpactPreview()
    XCTAssertEqual(preview.lifecycleImpactPreview?.generation, 7)
    let confirmed = await fixture.confirmRecoveryImpactPreview()
    guard case .confirmed(let display) = confirmed.lifecycleRecovery else { return XCTFail("fixture label must be retained") }
    XCTAssertEqual(display.generation, 7)
    XCTAssertFalse(fixture.lifecycleDispatchIsProductionComposed)
  }
}
